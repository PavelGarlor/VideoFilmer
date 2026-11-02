import AVFoundation
import Foundation

/// The routes behind ControlServer. Everything a person can do in the window, a tool can do here.
extension AppModel {
    typealias Response = ControlServer.Response

    func handleControl(_ req: ControlServer.Request) async -> Response {
        let body = req.json
        switch (req.method, req.route) {
        case ("GET", "/status"):
            return .json(statusJSON())

        case ("GET", "/settings"):
            return .json(settingsJSON())

        case ("POST", "/settings"):
            guard phase == .idle else { return busy() }
            return updateSettings(with: body)

        case ("POST", "/video"):
            guard phase == .idle else { return busy() }
            guard let path = body["path"] as? String else { return .error("Send {\"path\": \"/path/to/video.mp4\"}.") }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else { return .error("No file at \(url.path).") }
            loadVideo(url)
            for _ in 0..<40 where videoDuration == nil { try? await Task.sleep(for: .milliseconds(100)) }
            return .json(statusJSON())

        case ("POST", "/script"):
            guard phase == .idle else { return busy() }
            if let text = body["text"] as? String {
                settings.script = text
                prompter.reset()
            } else if let path = body["path"] as? String {
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return .error("Couldn't read \(url.path) as text.") }
                settings.script = text
                prompter.reset()
            } else {
                return .error("Send {\"text\": \"…\"} or {\"path\": \"/path/to/script.txt\"}.")
            }
            return .json(statusJSON())

        case ("POST", "/script/line"):
            guard phase == .idle else { return busy() }
            guard let i = body["line"] as? Int, paceBlocks.indices.contains(i) else {
                return .error("Send {\"line\": index from script.lines in /status, \"text\"?: \"…\", \"start\"?: seconds}.")
            }
            let row = paceBlocks[i].line.sourceIndex
            if let text = body["text"] as? String { editLine(sourceIndex: row, body: text) }
            if let start = (body["start"] as? Double) ?? (body["start"] as? Int).map(Double.init) {
                guard videoDuration != nil else { return .error("Load a video before setting line times.") }
                let blocks = paceBlocks
                guard let j = blocks.firstIndex(where: { $0.line.sourceIndex == row }) else { return .json(statusJSON()) }
                let lo = j > 0 ? blocks[j - 1].start + 0.3 : 0
                let hi = (j + 1 < blocks.count ? blocks[j + 1].start : videoDuration ?? start) - 0.3
                var starts = Dictionary(uniqueKeysWithValues: blocks.map { ($0.line.sourceIndex, $0.start) })
                starts[row] = min(max(start, lo), hi)
                setLineStarts(starts)
            }
            return .json(statusJSON())

        case ("POST", "/record"), ("POST", "/rehearse"):
            guard phase == .idle else { return busy() }
            return await runTakeRemotely(record: req.route == "/record", body: body)

        case ("POST", "/stop"):
            stopTake()
            if body["wait"] as? Bool ?? true { await waitWhile { $0 == .saving } }
            return .json(statusJSON())

        case ("POST", "/review"):
            guard phase == .reviewing, let review else { return .error("No take is being reviewed.", status: 409) }
            switch body["action"] as? String {
            case "save":
                if !(await saveReview()) { return .error(status.isEmpty ? "Nothing to save." : status) }
            case "retake" where review.isNew: retake()
            case "discard" where review.isNew: discardReview()
            case "close": closeReview()
            default: return .error("action must be save, retake or discard (fresh take), or save / close (saved take).")
            }
            return .json(statusJSON())

        case ("POST", "/review/mix"):
            guard phase == .reviewing, review?.mix != nil else {
                return .error("No take with adjustable audio is being reviewed.", status: 409)
            }
            setReviewMix(voice: body["voiceVolume"] as? Double, video: body["videoVolume"] as? Double)
            return .json(statusJSON())

        case ("POST", "/takes/open"):
            guard phase == .idle else { return busy() }
            guard let path = body["path"] as? String, let take = takes.first(where: { $0.url.path == path }) else {
                return .error("Unknown take. See takes in /status.")
            }
            open(take)
            return .json(statusJSON())

        case ("POST", "/jump"):
            guard let word = body["word"] as? Int else { return .error("Send {\"word\": index}.") }
            prompter.jump(to: word)
            return .json(statusJSON())

        case ("POST", "/guide"):
            cameraGuide = (body["tab"] as? String) == "camera" ? .camera : .iPhone
            return .json(["ok": true])

        case ("GET", "/snapshot"):
            guard let png = await engine.snapshotPNG() else { return .error("No frame yet.", status: 503) }
            return .png(png)

        case ("GET", "/frame"):
            guard let path = req.query["path"] else { return .error("Pass ?path=…&t=seconds.") }
            let t = Double(req.query["t"] ?? "0") ?? 0
            do {
                guard let png = try await RecorderEngine.framePNG(of: URL(fileURLWithPath: path), at: t) else {
                    return .error("Couldn't read a frame.")
                }
                return .png(png)
            } catch {
                return .error(error.localizedDescription)
            }

        default:
            return .error("Unknown route \(req.method) \(req.route).", status: 404)
        }
    }

    // MARK: - Takes

    /// Starts a take. With `duration`, stops it after that many seconds of recording;
    /// with `wait` (default true when a duration is given) answers once the take is ready to review.
    private func runTakeRemotely(record: Bool, body: [String: Any]) async -> Response {
        let duration = (body["duration"] as? Double) ?? (body["duration"] as? Int).map(Double.init)
        // Right after launch the camera needs a moment; don't record a blank frame.
        if settings.layout != .voiceOnly {
            for _ in 0..<50 where !engine.isCameraLive { try? await Task.sleep(for: .milliseconds(100)) }
        }
        startTake(record: record)
        guard let duration else { return .json(statusJSON()) }

        // Wait for the countdown, then for the requested length.
        await waitWhile { $0 == .countdown }
        let running: AppModel.Phase = record ? .recording : .rehearsing
        let start = Date()
        while phase == running, Date().timeIntervalSince(start) < duration {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if phase == running { stopTake() }
        if body["wait"] as? Bool ?? true { await waitWhile { $0 == .saving } }
        return .json(statusJSON())
    }

    private func waitWhile(_ condition: (AppModel.Phase) -> Bool) async {
        let start = Date()
        while condition(phase), Date().timeIntervalSince(start) < 600 {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - Settings

    private func updateSettings(with body: [String: Any]) -> Response {
        guard !body.isEmpty else { return .json(settingsJSON()) }
        let known = Set(Mirror(reflecting: settings).children.compactMap(\.label))
        let unknown = body.keys.filter { !known.contains($0) }
        guard unknown.isEmpty else { return .error("Unknown settings: \(unknown.joined(separator: ", ")). Known: \(known.sorted().joined(separator: ", ")).") }
        do {
            var dict = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any] ?? [:]
            for (key, value) in body { dict[key] = value is NSNull ? nil : value }
            settings = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: dict))
        } catch {
            return .error("Invalid value: \(error). Allowed values: \(allowedValues())")
        }
        return .json(settingsJSON())
    }

    private func allowedValues() -> String {
        "layout: \(LayoutKind.allCases.map(\.rawValue)), aspect: \(AspectKind.allCases.map(\.rawValue)), "
            + "corner: \(Corner.allCases.map(\.rawValue)), pipShape: \(PipShape.allCases.map(\.rawValue)), promptMode: \(PromptMode.allCases.map(\.rawValue))"
    }

    private func settingsJSON() -> [String: Any] {
        var dict = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(settings))) as? [String: Any] ?? [:]
        dict["script"] = nil // shown under "script" in /status
        dict["_allowed"] = [
            "layout": LayoutKind.allCases.map(\.rawValue),
            "aspect": AspectKind.allCases.map(\.rawValue),
            "corner": Corner.allCases.map(\.rawValue),
            "pipShape": PipShape.allCases.map(\.rawValue),
            "promptMode": PromptMode.allCases.map(\.rawValue),
            "countdown": [0, 3, 5],
            "ranges": "split 0.25–0.75, pipSize 0.2–0.6, wpm 80–240, fontSize 22–80, prompterHeight 0.2–0.75, videoVolume 0–1",
        ]
        return dict
    }

    // MARK: - Status

    private func busy() -> Response {
        .error("The app is busy (\(phase)). Stop or finish the review first.", status: 409)
    }

    func statusJSON() -> [String: Any] {
        let script = prompter.script
        let text = script.text.string as NSString
        let current = prompter.current
        let elapsed = phase == .recording || phase == .rehearsing ? stats.elapsed : 0
        return [
            "phase": "\(phase)",
            "status": status,
            "countdown": countdownValue ?? NSNull(),
            "elapsed": (elapsed * 10).rounded() / 10,
            "micLevelDb": Double(stats.micLevel),
            "cameraLive": engine.isCameraLive,
            "video": videoURL.map { ["path": $0.path, "duration": videoDuration ?? NSNull(), "info": videoInfo] as [String: Any] } ?? NSNull(),
            "script": [
                "words": script.words.count,
                "timedLines": script.anchors.map { $0.time },
                "currentWordIndex": current,
                "currentWord": current < script.words.count ? text.substring(with: script.words[current].range) : NSNull(),
                "summary": prompter.summary(mode: settings.promptMode, wpm: settings.wpm, videoDuration: videoDuration),
                "lines": paceBlocks.enumerated().map { i, b in
                    [
                        "line": i, "text": b.line.body,
                        "start": (b.start * 10).rounded() / 10, "end": (b.end * 10).rounded() / 10,
                        "wpm": Int(b.wpm.rounded()), "pace": Pace.label(b.wpm),
                    ] as [String: Any]
                },
                "text": settings.script,
            ] as [String: Any],
            "layout": [
                "layout": settings.layout.rawValue,
                "aspect": settings.aspect.rawValue,
                "promptMode": settings.promptMode.rawValue,
            ],
            "review": review.map {
                [
                    "path": $0.take.url.path, "isNew": $0.isNew, "duration": $0.take.duration ?? NSNull(),
                    "voiceVolume": $0.mix?.voiceVolume ?? NSNull(), "videoVolume": $0.mix?.videoVolume ?? NSNull(),
                    "unsavedAudioChanges": $0.hasUnsavedMix,
                    "cameraPath": $0.mix?.cameraPath ?? NSNull(),
                ] as [String: Any]
            } ?? NSNull(),
            "takes": takes.prefix(20).map { ["path": $0.url.path, "duration": $0.duration ?? NSNull()] as [String: Any] },
            "takesFolder": Self.takesFolder.path,
            "devices": [
                "cameras": cameras.map {
                    ["id": $0.uniqueID, "name": $0.localizedName,
                     "kind": $0.deviceType == .continuityCamera ? "iPhone" : $0.deviceType == .external ? "external" : "built-in"]
                },
                "microphones": microphones.map { ["id": $0.uniqueID, "name": $0.localizedName] },
            ],
        ]
    }
}
