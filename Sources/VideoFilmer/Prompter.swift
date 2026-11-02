import AVFoundation
import Speech

/// Decides which script word is "now": from the video clock, a fixed speed, or your voice.
@MainActor
final class PrompterController: ObservableObject {
    @Published private(set) var script = ParsedScript.parse("", fontSize: 40)
    @Published private(set) var revision = 0
    /// Index of the word to read next (`words.count` once finished).
    @Published private(set) var current = 0

    var onMessage: ((String) -> Void)?
    let speech = SpeechFollower()

    private(set) var isRunning = false
    private var mode: PromptMode = .video
    private var times: [Double] = []
    private var endTime: Double = 0
    private var clockOrigin: CFTimeInterval = 0
    private weak var player: AVPlayer?
    private var voiceBase = 0
    /// Highlight words a moment before they're due, so your eyes are already there.
    private let lead = 0.25

    func rebuild(text: String, fontSize: Double) {
        script = .parse(text, fontSize: fontSize)
        revision += 1
        // Small edits keep your place; loading a new script calls reset().
        current = min(current, script.words.count)
    }

    func reset() { current = 0 }

    func jump(to index: Int) {
        let i = max(0, min(index, script.words.count))
        current = i
        guard isRunning else { return }
        switch mode {
        case .speed: if i < times.count { clockOrigin = CACurrentMediaTime() - times[i] }
        case .voice: voiceBase = i
        case .video: break // the video clock decides
        }
    }

    func start(mode requested: PromptMode, wpm: Double, language: String, player: AVPlayer?, videoDuration: Double?) {
        mode = (requested == .video && videoDuration == nil) ? .speed : requested
        self.player = player
        (times, endTime) = script.times(videoDuration: mode == .video ? videoDuration : nil, wpm: wpm)
        isRunning = true
        switch mode {
        case .speed: clockOrigin = CACurrentMediaTime() - (current < times.count ? times[current] : 0)
        case .voice: startVoice(language: language)
        case .video: break
        }
    }

    func stop() {
        isRunning = false
        speech.stop()
    }

    func tick() {
        guard isRunning, mode != .voice, !times.isEmpty else { return }
        let clock = mode == .video ? (player?.currentTime().seconds ?? 0) : CACurrentMediaTime() - clockOrigin
        let t = clock + lead
        var next = times.count
        if t < endTime {
            var lo = 0, hi = times.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if times[mid] <= t { lo = mid + 1 } else { hi = mid }
            }
            next = max(0, lo - 1)
        }
        if next != current { current = next }
    }

    /// One-line description of how the script fits, for the sidebar.
    func summary(mode: PromptMode, wpm: Double, videoDuration: Double?) -> String {
        let n = script.words.count
        guard n > 0 else { return "No script yet." }
        let anchors = script.anchors.isEmpty ? "" : ", \(script.anchors.count) timed lines"
        switch mode {
        case .video:
            guard let d = videoDuration, d > 0 else { return "\(n) words\(anchors). Load a video to sync; until then it uses the fixed speed." }
            return "\(n) words over \(formatTime(d)) of video, about \(Int((Double(n) / (d / 60)).rounded())) words/min\(anchors)."
        case .speed:
            let end = script.times(videoDuration: nil, wpm: wpm).end
            return "\(n) words, about \(formatTime(end)) at \(Int(wpm)) words/min."
        case .voice:
            return "\(n) words. The highlight moves as you speak (Apple speech recognition)."
        }
    }

    private func startVoice(language: String) {
        voiceBase = current
        speech.onWords = { [weak self] heard in
            guard let self, self.isRunning else { return }
            var p = self.voiceBase
            for w in heard { p = ScriptMatcher.advance(w, from: p, in: self.script.words) }
            if p > self.current { self.current = p }
        }
        speech.onUtteranceEnd = { [weak self] in
            guard let self else { return }
            self.voiceBase = self.current
        }
        speech.onError = { [weak self] message in self?.onMessage?(message) }
        Task {
            guard await SpeechFollower.authorize() else {
                onMessage?("Allow Speech Recognition for VideoFilmer in System Settings › Privacy & Security.")
                return
            }
            if isRunning { speech.start(language: language) }
        }
    }
}

/// Streams mic audio into Apple's speech recognizer and reports the words heard in the current utterance.
final class SpeechFollower {
    /// Main thread. Normalized words of the current utterance so far.
    var onWords: (([String]) -> Void)?
    var onUtteranceEnd: (() -> Void)?
    var onError: ((String) -> Void)?

    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private var active = false
    private var failures = 0
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest? // guarded by lock

    static func authorize() async -> Bool {
        await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
    }

    func start(language: String) {
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: language)), r.isAvailable else {
            onError?("Speech recognition isn't available for \(language).")
            return
        }
        recognizer = r
        active = true
        failures = 0
        beginTask()
    }

    func stop() {
        active = false
        lock.withLock {
            request?.endAudio()
            request = nil
        }
        task?.cancel()
        task = nil
    }

    /// Called from the engine's queue.
    func append(_ sample: CMSampleBuffer) {
        lock.withLock { request }?.appendAudioSampleBuffer(sample)
    }

    private func beginTask() {
        guard active, let recognizer else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        lock.withLock { request = req }
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.active, self.lock.withLock({ self.request === req }) else { return }
                if let result {
                    self.failures = 0
                    self.onWords?(ScriptMatcher.words(in: result.bestTranscription.formattedString))
                }
                guard error != nil || result?.isFinal == true else { return }
                // Recognition ends after a pause or a time limit; keep listening with a fresh task.
                self.onUtteranceEnd?()
                if result == nil { self.failures += 1 }
                if self.failures > 8 {
                    self.onError?("Speech recognition stopped: \(error?.localizedDescription ?? "unknown error")")
                    self.stop()
                    return
                }
                self.lock.withLock { self.request?.endAudio() }
                self.beginTask()
            }
        }
    }
}
