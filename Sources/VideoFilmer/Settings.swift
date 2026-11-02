import CoreGraphics
import Foundation

enum LayoutKind: String, Codable, CaseIterable, Identifiable {
    case camTop, videoTop, pip, side, voiceOnly, camOnly

    var id: String { rawValue }
    var label: String {
        switch self {
        case .camTop: "Me top, video bottom"
        case .videoTop: "Video top, me bottom"
        case .pip: "Me in a corner"
        case .side: "Side by side"
        case .voiceOnly: "Voice-over only"
        case .camOnly: "Only me"
        }
    }
    var usesSplit: Bool { self == .camTop || self == .videoTop || self == .side }
}

enum AspectKind: String, Codable, CaseIterable, Identifiable {
    case vertical, horizontal, square

    var id: String { rawValue }
    var label: String {
        switch self {
        case .vertical: "Vertical 9:16 (Reels, TikTok, Shorts)"
        case .horizontal: "Horizontal 16:9 (YouTube)"
        case .square: "Square 1:1"
        }
    }
    var size: CGSize {
        switch self {
        case .vertical: CGSize(width: 1080, height: 1920)
        case .horizontal: CGSize(width: 1920, height: 1080)
        case .square: CGSize(width: 1080, height: 1080)
        }
    }
}

enum Corner: String, Codable, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight

    var id: String { rawValue }
    var label: String {
        switch self {
        case .topLeft: "Top left"
        case .topRight: "Top right"
        case .bottomLeft: "Bottom left"
        case .bottomRight: "Bottom right"
        }
    }
    var isLeft: Bool { self == .topLeft || self == .bottomLeft }
    var isTop: Bool { self == .topLeft || self == .topRight }
}

enum PipShape: String, Codable, CaseIterable, Identifiable {
    case circle, square, tall

    var id: String { rawValue }
    var label: String {
        switch self {
        case .circle: "Round"
        case .square: "Square"
        case .tall: "Tall"
        }
    }
}

enum PromptMode: String, Codable, CaseIterable, Identifiable {
    case video, voice, speed

    var id: String { rawValue }
    var label: String {
        switch self {
        case .video: "The video timing"
        case .voice: "My voice"
        case .speed: "A fixed speed"
        }
    }
}

/// Everything the compositor needs to draw a frame.
struct RenderSettings: Equatable {
    var layout: LayoutKind = .camTop
    var aspect: AspectKind = .vertical
    var split: Double = 0.5
    var corner: Corner = .topRight
    var pipSize: Double = 0.38
    var pipShape: PipShape = .circle
    var fitWholeVideo = false
    var mirror = true
}

struct AppSettings: Codable, Equatable {
    var layout: LayoutKind = .camTop
    var aspect: AspectKind = .vertical
    var split: Double = 0.5
    var corner: Corner = .topRight
    var pipSize: Double = 0.38
    var pipShape: PipShape = .circle
    var fitWholeVideo = false
    var mirrorCamera = true

    var promptMode: PromptMode = .video
    var wpm: Double = 150
    var language: String = "en-US"
    var fontSize: Double = 40
    var prompterHeight: Double = 0.4

    var includeVideoAudio = true
    var videoVolume: Double = 0.35
    var monitorVideoAudio = false
    var restartVideo = true
    var stopOnVideoEnd = true
    var countdown: Int = 3
    var saveCameraSeparately = false
    var cameraID: String?
    var micID: String?

    var script: String = ""
    var videoPath: String?

    var render: RenderSettings {
        RenderSettings(layout: layout, aspect: aspect, split: split, corner: corner, pipSize: pipSize,
                       pipShape: pipShape, fitWholeVideo: fitWholeVideo, mirror: mirrorCamera)
    }

    private static let key = "settings.v1"

    static func load() -> AppSettings {
        // Lay saved values over the defaults, so settings added in newer versions don't wipe the rest.
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaults = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings())) as? [String: Any]
        else { return AppSettings() }
        var merged = defaults.merging(saved) { _, new in new }
        // Older versions had a circle on/off switch.
        if let circle = saved["pipCircle"] as? Bool, saved["pipShape"] == nil { merged["pipShape"] = circle ? "circle" : "tall" }
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged),
              let s = try? JSONDecoder().decode(AppSettings.self, from: mergedData) else { return AppSettings() }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

func formatTime(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.isFinite ? seconds : 0))
    return String(format: "%d:%02d", s / 60, s % 60)
}
