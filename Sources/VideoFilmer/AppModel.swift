import AppKit
import AVFoundation
import UniformTypeIdentifiers

struct Take: Identifiable {
    let url: URL
    let date: Date
    var duration: Double?
    var id: URL { url }
}

/// Fast-changing numbers, kept apart so they don't redraw the whole window.
final class LiveStats: ObservableObject {
    @Published var elapsed: Double = 0
    @Published var micLevel: Float = -160
}

@MainActor
final class AppModel: ObservableObject {
    enum Phase { case idle, countdown, rehearsing, recording, saving, reviewing }

    /// A take being watched: either a fresh one waiting to be saved or discarded, or a saved one.
    struct Review {
        let take: Take
        let isNew: Bool
        /// Audio levels being tried. Nil for takes recorded before levels were kept.
        var mix: TakeMix?
        /// Levels on disk, to tell whether there are unsaved changes.
        var savedMix: TakeMix?

        var hasUnsavedMix: Bool { mix != nil && mix != savedMix }
    }

    @Published var settings: AppSettings { didSet { settingsChanged(from: oldValue) } }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var countdownValue: Int?
    @Published var status = ""
    @Published private(set) var cameras: [AVCaptureDevice] = []
    @Published private(set) var microphones: [AVCaptureDevice] = []
    @Published private(set) var videoURL: URL?
    @Published private(set) var videoInfo = "No video yet. You can also drop one on the preview."
    @Published private(set) var videoDuration: Double?
    @Published private(set) var takes: [Take] = []
    @Published private(set) var review: Review?
    /// Source row of the script line being edited in the teleprompter.
    @Published var editingLine: Int?
    /// The camera help sheet, when open.
    @Published var cameraGuide: CameraGuideView.Tab?
    /// Frames across the AI video, for the pace timeline.
    @Published private(set) var thumbnails: [CGImage] = []

    let engine = RecorderEngine()
    let prompter = PrompterController()
    let stats = LiveStats()

    private var timer: Timer?
    private let controlServer = ControlServer()
    private var takeTask: Task<Void, Never>?
    private var sessionStart: CFTimeInterval = 0
    private var recordStartHost = CMTime.invalid
    private var videoPlayHost = CMTime.invalid
    private var videoStartPosition: Double = 0

    static let takesFolder: URL = {
        let url = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("VideoFilmer")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Fresh takes wait here until you save them.
    static let pendingFolder: URL = {
        let url = takesFolder.appendingPathComponent(".pending")
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    init() {
        settings = AppSettings.load()
        engine.update(settings.render)
        prompter.rebuild(text: settings.script, fontSize: settings.fontSize)
        prompter.onMessage = { [weak self] in self?.status = $0 }
        engine.onMicLevel = { [weak self] in self?.stats.micLevel = $0 }
        engine.onAudioSample = Self.forwardAudio(to: prompter.speech)
        applyPlayerVolume()

        let center = NotificationCenter.default
        center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, (note.object as? AVPlayerItem) === self.engine.player.currentItem else { return }
                if self.settings.stopOnVideoEnd, self.phase == .recording || self.phase == .rehearsing { self.stopTake() }
            }
        }
        for (name, connected) in [(AVCaptureDevice.wasConnectedNotification, true), (AVCaptureDevice.wasDisconnectedNotification, false)] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let device = note.object as? AVCaptureDevice
                MainActor.assumeIsolated { self?.devicesChanged(device, connected: connected) }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        loadTakes()
        if let path = settings.videoPath, FileManager.default.fileExists(atPath: path) {
            loadVideo(URL(fileURLWithPath: path))
        }
        controlServer.handler = { [weak self] request in
            await self?.handleControl(request) ?? .error("Shutting down.", status: 503)
        }
        do {
            try controlServer.start()
        } catch {
            status = "Remote control unavailable: \(error.localizedDescription)"
        }
        Task { await setUpDevices() }
    }

    /// Built outside the main actor: it runs on the engine's queue.
    nonisolated private static func forwardAudio(to speech: SpeechFollower) -> (CMSampleBuffer) -> Void {
        { speech.append($0) }
    }

    var isBusy: Bool { phase != .idle }

    // MARK: - Settings

    private func settingsChanged(from old: AppSettings) {
        if settings.render != old.render { engine.update(settings.render) }
        if settings.script != old.script || settings.fontSize != old.fontSize {
            prompter.rebuild(text: settings.script, fontSize: settings.fontSize)
        }
        if settings.cameraID != old.cameraID || settings.micID != old.micID {
            engine.useDevices(cameraID: settings.cameraID, micID: settings.micID)
        }
        applyPlayerVolume()
        settings.save()
    }

    private func applyPlayerVolume() {
        engine.player.volume = settings.monitorVideoAudio ? Float(settings.videoVolume) : 0
    }

    // MARK: - Devices

    private func setUpDevices() async {
        let camOK = await AVCaptureDevice.requestAccess(for: .video)
        let micOK = await AVCaptureDevice.requestAccess(for: .audio)
        if !camOK || !micOK {
            status = "Allow the camera and microphone for VideoFilmer in System Settings › Privacy & Security."
        }
        refreshDevices()
        engine.useDevices(cameraID: settings.cameraID, micID: settings.micID)
    }

    private func refreshDevices() {
        cameras = RecorderEngine.cameras()
        microphones = RecorderEngine.microphones()
    }

    /// A camera or mic was plugged in or out.
    private func devicesChanged(_ device: AVCaptureDevice?, connected: Bool) {
        refreshDevices()
        if let device {
            let kind = device.hasMediaType(.video) ? "Camera" : "Microphone"
            status = connected
                ? "\(kind) “\(device.localizedName)” connected. Choose it under \(kind) in the sidebar."
                : "\(kind) “\(device.localizedName)” disconnected."
        }
        // Re-attach so a selected device that came back is used again, or the default takes over.
        if phase != .recording && phase != .countdown {
            engine.useDevices(cameraID: settings.cameraID, micID: settings.micID)
        }
    }

    // MARK: - Sources

    func chooseVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video]
        panel.message = "Choose the AI video"
        if panel.runModal() == .OK, let url = panel.url { loadVideo(url) }
    }

    func chooseScript() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.message = "Choose the script"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            settings.script = text
            prompter.reset()
        } else {
            status = "Couldn't read \(url.lastPathComponent) as text."
        }
    }

    func loadVideo(_ url: URL) {
        guard !isBusy else { return }
        videoURL = url
        settings.videoPath = url.path
        videoDuration = nil
        thumbnails = []
        videoInfo = url.lastPathComponent
        engine.loadVideo(url: url)
        Task {
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration).seconds, duration > 0 else {
                videoInfo = "\(url.lastPathComponent) couldn't be read as a video."
                return
            }
            var dims = ""
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
                let s = size.applying(transform)
                dims = " · \(Int(abs(s.width)))×\(Int(abs(s.height)))"
            }
            let hasAudio = !((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty
            videoDuration = duration
            videoInfo = "\(url.lastPathComponent)\(dims) · \(formatTime(duration))\(hasAudio ? "" : " · no audio")"

            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 160, height: 160)
            var frames: [CGImage] = []
            for i in 0..<24 {
                let t = CMTime(seconds: duration * (Double(i) + 0.5) / 24, preferredTimescale: 600)
                if let (image, _) = try? await generator.image(at: t) { frames.append(image) }
            }
            if videoURL == url { thumbnails = frames }
        }
    }

    // MARK: - Script editing

    /// Replaces the text of one script line, keeping its timing.
    func editLine(sourceIndex: Int, body: String) {
        guard phase == .idle, let line = prompter.script.lines.first(where: { $0.sourceIndex == sourceIndex }) else { return }
        settings.script = ParsedScript.replacingBody(in: settings.script, line: line, with: body)
    }

    /// Pins lines (keyed by source row) to new start times in the video.
    func setLineStarts(_ starts: [Int: Double]) {
        guard phase == .idle else { return }
        settings.script = ParsedScript.applyingStarts(starts, to: settings.script, lines: prompter.script.lines)
    }

    /// Current timing of each spoken line.
    var paceBlocks: [PaceBlock] {
        prompter.script.paceBlocks(videoDuration: videoDuration, wpm: settings.wpm)
    }

    // MARK: - Takes

    func startTake(record: Bool) {
        guard phase == .idle else { return }
        status = ""
        phase = .countdown
        takeTask = Task { await runTake(record: record) }
    }

    private func runTake(record: Bool) async {
        let player = engine.player
        if settings.restartVideo {
            prompter.reset()
            if videoURL != nil { await player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) }
        }
        for n in stride(from: settings.countdown, to: 0, by: -1) {
            countdownValue = n
            try? await Task.sleep(for: .seconds(1))
            guard phase == .countdown, !Task.isCancelled else { countdownValue = nil; return }
        }
        countdownValue = nil

        if record {
            let url = Self.pendingFolder.appendingPathComponent(Self.newTakeName())
            let cameraURL = settings.saveCameraSeparately
                ? Self.pendingFolder.appendingPathComponent(url.deletingPathExtension().lastPathComponent + " (camera).mp4")
                : nil
            do {
                recordStartHost = try engine.beginRecording(to: url, cameraURL: cameraURL)
            } catch {
                status = "Couldn't start recording: \(error.localizedDescription)"
                phase = .idle
                return
            }
        }
        videoStartPosition = player.currentTime().seconds
        if videoURL != nil { player.play() }
        videoPlayHost = CMClockGetTime(CMClockGetHostTimeClock())
        sessionStart = CACurrentMediaTime()
        stats.elapsed = 0
        phase = record ? .recording : .rehearsing
        prompter.start(mode: settings.promptMode, wpm: settings.wpm, language: settings.language,
                       player: videoURL != nil ? player : nil, videoDuration: videoDuration)
    }

    func stopTake() {
        switch phase {
        case .countdown:
            takeTask?.cancel()
            countdownValue = nil
            phase = .idle
        case .rehearsing:
            engine.player.pause()
            prompter.stop()
            phase = .idle
        case .recording:
            engine.player.pause()
            prompter.stop()
            phase = .saving
            status = "Saving…"
            Task { await finishTake() }
        case .idle, .saving, .reviewing:
            break
        }
    }

    private func finishTake() async {
        guard let (url, duration, cameraURL) = await engine.finishRecording() else {
            status = "Nothing was recorded."
            phase = .idle
            return
        }
        // Voice and video sound stay separate until the take is saved, so the levels can be tuned first.
        let mix = TakeMix(rawPath: url.path, videoPath: videoURL?.path,
                          offset: (videoPlayHost - recordStartHost).seconds, sourceStart: videoStartPosition,
                          voiceVolume: 1, videoVolume: settings.includeVideoAudio ? settings.videoVolume : 0,
                          cameraPath: cameraURL?.path)
        status = ""
        review = Review(take: Take(url: url, date: Date(), duration: duration), isNew: true, mix: mix)
        phase = .reviewing
    }

    // MARK: - Review

    /// Changes the audio levels of the take being reviewed (0…1 each).
    func setReviewMix(voice: Double? = nil, video: Double? = nil) {
        guard var r = review, var mix = r.mix else { return }
        if let voice { mix.voiceVolume = max(0, min(1, voice)) }
        if let video { mix.videoVolume = max(0, min(1, video)) }
        r.mix = mix
        review = r
    }

    /// Fresh take: mixes it into the takes folder. Saved take: re-mixes it with the new levels.
    @discardableResult
    func saveReview() async -> Bool {
        guard let r = review, phase == .reviewing else { return false }
        guard let mix = r.mix else {
            if r.isNew { status = "Nothing to save." }
            return false
        }
        phase = .saving
        status = "Saving…"
        defer { if phase == .saving { phase = .reviewing } }
        do {
            if r.isNew {
                let dest = Self.takesFolder.appendingPathComponent(r.take.url.lastPathComponent)
                try await TakeAudio.export(mix, to: dest)
                var saved = mix
                saved.rawPath = TakeAudio.rawURL(for: dest).path
                try FileManager.default.moveItem(at: URL(fileURLWithPath: mix.rawPath), to: URL(fileURLWithPath: saved.rawPath))
                if let camera = mix.cameraPath {
                    let cameraDest = TakeAudio.cameraURL(for: dest)
                    try FileManager.default.moveItem(at: URL(fileURLWithPath: camera), to: cameraDest)
                    saved.cameraPath = cameraDest.path
                }
                try TakeAudio.saveMix(saved, for: dest)
                takes.insert(Take(url: dest, date: r.take.date, duration: r.take.duration), at: 0)
                status = "Saved \(dest.lastPathComponent)"
                closeReview()
            } else {
                try await TakeAudio.export(mix, to: r.take.url)
                try TakeAudio.saveMix(mix, for: r.take.url)
                review?.savedMix = mix
                status = "Saved the new audio levels."
            }
            return true
        } catch {
            status = "Couldn't save: \(error.localizedDescription)"
            return false
        }
    }

    /// Throws the fresh take away and starts a new one.
    func retake() {
        discardReview()
        startTake(record: true)
    }

    /// Throws a fresh take away, or just closes a saved one.
    func discardReview() {
        if let r = review, r.isNew {
            try? FileManager.default.removeItem(at: r.take.url)
            if let camera = r.mix?.cameraPath { try? FileManager.default.removeItem(atPath: camera) }
        }
        closeReview()
    }

    func closeReview() {
        review = nil
        phase = .idle
    }

    func open(_ take: Take) {
        guard phase == .idle else { return }
        let mix = TakeAudio.loadMix(for: take.url)
        review = Review(take: take, isNew: false, mix: mix, savedMix: mix)
        phase = .reviewing
    }

    /// Moves a saved take (and its raw recording) to the Trash.
    func delete(_ take: Take) {
        do {
            let camera = TakeAudio.loadMix(for: take.url)?.cameraPath.map { URL(fileURLWithPath: $0) }
            try FileManager.default.trashItem(at: take.url, resultingItemURL: nil)
            for extra in [TakeAudio.rawURL(for: take.url), TakeAudio.mixURL(for: take.url)] + (camera.map { [$0] } ?? [])
            where FileManager.default.fileExists(atPath: extra.path) {
                try? FileManager.default.trashItem(at: extra, resultingItemURL: nil)
            }
            takes.removeAll { $0.url == take.url }
            status = "Moved \(take.url.lastPathComponent) to the Trash."
        } catch {
            status = "Couldn't delete: \(error.localizedDescription)"
        }
        if review?.take.url == take.url { closeReview() }
    }

    func reveal(_ take: Take) { NSWorkspace.shared.activateFileViewerSelecting([take.url]) }
    func openTakesFolder() { NSWorkspace.shared.open(Self.takesFolder) }

    private func loadTakes() {
        let keys: [URLResourceKey] = [.creationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.takesFolder, includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles])) ?? []
        takes = files.filter { $0.pathExtension.lowercased() == "mp4" }
            .map { Take(url: $0, date: (try? $0.resourceValues(forKeys: Set(keys)).creationDate) ?? .distantPast) }
            .sorted { $0.date > $1.date }
    }

    private static func newTakeName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Take \(f.string(from: Date())).mp4"
    }

    // MARK: - Clock

    private func tick() {
        if phase == .recording || phase == .rehearsing { stats.elapsed = CACurrentMediaTime() - sessionStart }
        prompter.tick()
    }
}
