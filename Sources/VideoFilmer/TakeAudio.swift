import AVFoundation

/// How a take's two sound sources are balanced. Kept next to each saved take so it can be remixed later.
struct TakeMix: Codable, Equatable {
    /// Camera + voice, exactly as recorded.
    var rawPath: String
    /// The AI video whose own sound plays under the voice.
    var videoPath: String?
    /// Seconds into the recording when the AI video started playing.
    var offset: Double
    /// Where in the AI video playback started.
    var sourceStart: Double
    var voiceVolume: Double = 1
    var videoVolume: Double = 0.35
    /// The clean camera recorded on its own (same start and length), if that option was on.
    var cameraPath: String?
}

/// Builds and exports the final sound of a take from its raw recording and the AI video.
enum TakeAudio {
    struct Plan {
        let composition: AVMutableComposition
        let voiceTracks: [AVMutableCompositionTrack]
        let videoSoundTrack: AVMutableCompositionTrack?

        func audioMix(voice: Double, video: Double) -> AVAudioMix {
            let mix = AVMutableAudioMix()
            var params = voiceTracks.map { track -> AVMutableAudioMixInputParameters in
                let p = AVMutableAudioMixInputParameters(track: track)
                p.setVolume(Float(max(0, min(1, voice))), at: .zero)
                return p
            }
            if let track = videoSoundTrack {
                let p = AVMutableAudioMixInputParameters(track: track)
                p.setVolume(Float(max(0, min(1, video))), at: .zero)
                params.append(p)
            }
            mix.inputParameters = params
            return mix
        }
    }

    /// Raw recordings and mix settings of saved takes live in `<takes>/.edit`.
    static let editFolder: URL = {
        let url = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VideoFilmer/.edit")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Camera-only files of saved takes live in `<takes>/Camera`.
    static let cameraFolder: URL = {
        let url = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VideoFilmer/Camera")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func cameraURL(for take: URL) -> URL {
        cameraFolder.appendingPathComponent(take.deletingPathExtension().lastPathComponent + " (camera).mp4")
    }

    static func rawURL(for take: URL) -> URL {
        editFolder.appendingPathComponent(take.deletingPathExtension().lastPathComponent + ".raw.mp4")
    }

    static func mixURL(for take: URL) -> URL {
        editFolder.appendingPathComponent(take.deletingPathExtension().lastPathComponent + ".json")
    }

    static func loadMix(for take: URL) -> TakeMix? {
        guard let data = try? Data(contentsOf: mixURL(for: take)),
              let mix = try? JSONDecoder().decode(TakeMix.self, from: data),
              FileManager.default.fileExists(atPath: mix.rawPath) else { return nil }
        return mix
    }

    static func saveMix(_ mix: TakeMix, for take: URL) throws {
        try JSONEncoder().encode(mix).write(to: mixURL(for: take))
    }

    static func plan(for mix: TakeMix) async throws -> Plan {
        let raw = AVURLAsset(url: URL(fileURLWithPath: mix.rawPath))
        let rawDuration = try await raw.load(.duration)
        let fullRange = CMTimeRange(start: .zero, duration: rawDuration)
        let comp = AVMutableComposition()

        for track in try await raw.loadTracks(withMediaType: .video) {
            try comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)?
                .insertTimeRange(fullRange, of: track, at: .zero)
        }
        var voiceTracks: [AVMutableCompositionTrack] = []
        for track in try await raw.loadTracks(withMediaType: .audio) {
            if let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try t.insertTimeRange(fullRange, of: track, at: .zero)
                voiceTracks.append(t)
            }
        }

        var videoSound: AVMutableCompositionTrack?
        if let path = mix.videoPath, FileManager.default.fileExists(atPath: path) {
            let ai = AVURLAsset(url: URL(fileURLWithPath: path))
            if let aiAudio = try await ai.loadTracks(withMediaType: .audio).first {
                let aiDuration = try await ai.load(.duration)
                let at = CMTime(seconds: max(0, mix.offset), preferredTimescale: 48_000)
                let start = CMTime(seconds: mix.sourceStart, preferredTimescale: 48_000)
                let length = CMTimeMinimum(aiDuration - start, rawDuration - at)
                if length > .zero, let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    try t.insertTimeRange(CMTimeRange(start: start, duration: length), of: aiAudio, at: at)
                    videoSound = t
                }
            }
        }
        return Plan(composition: comp, voiceTracks: voiceTracks, videoSoundTrack: videoSound)
    }

    /// Writes the mixed take to `url`, replacing what's there.
    static func export(_ mix: TakeMix, to url: URL) async throws {
        let plan = try await plan(for: mix)
        guard let export = AVAssetExportSession(asset: plan.composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".export-\(UUID().uuidString).mp4")
        export.outputURL = tmp
        export.outputFileType = .mp4
        export.audioMix = plan.audioMix(voice: mix.voiceVolume, video: mix.videoVolume)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { c.resume() }
        }
        guard export.status == .completed else {
            try? FileManager.default.removeItem(at: tmp)
            throw export.error ?? CocoaError(.fileWriteUnknown)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }
}
