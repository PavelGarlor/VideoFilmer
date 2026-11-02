// Renders the Tuelang A1 cohort promo (1080×1920, 30 fps) with a soft music bed.
//
//   swiftc -O -swift-version 5 render.swift -o /tmp/render && /tmp/render <output-dir> [preview-dir] [file-name.mp4]
//
// Scene lengths follow script.txt: each line read at ~165 words/min with a short breath,
// and each element appears about when its words are spoken. Everything that matters
// sits in the middle band (y 480–1440) so it survives VideoFilmer's split layouts.

import AppKit
import AVFoundation
import CoreText

let W = 1080, H = 1920, fps = 30
let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let previewDir = CommandLine.arguments.count > 2 ? URL(fileURLWithPath: CommandLine.arguments[2]) : nil
let outputName = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "tuelang-a1-cohort.mp4"

// Tuelang brand colours (.claude/skills/tuelang-brand/brand.json).
let dark: UInt32 = 0x1C1C1E, light: UInt32 = 0xF4F4F6, lime: UInt32 = 0x95ED68
let orange: UInt32 = 0xF4A227, teal: UInt32 = 0x1A7A7A, white: UInt32 = 0xFFFFFF, gray: UInt32 = 0x8E8E93

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
func clamp(_ x: Double) -> Double { max(0, min(1, x)) }
func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
/// Top-left layout rect → Core Graphics rect.
func R(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x, y: CGFloat(H) - y - h, width: w, height: h) }

// MARK: - Drawing helpers

var ctx: CGContext!
var sceneAlpha: CGFloat = 1

func attributed(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: UInt32, _ align: CTTextAlignment, _ kern: CGFloat) -> NSAttributedString {
    var alignment = align
    let style = withUnsafePointer(to: &alignment) { ptr in
        CTParagraphStyleCreate([CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: ptr)], 1)
    }
    return NSAttributedString(string: s, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): NSFont.systemFont(ofSize: size, weight: weight),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): rgb(color),
        NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style,
        NSAttributedString.Key(kCTKernAttributeName as String): kern,
    ])
}

/// Draws wrapped text with its top at `y`. Returns its height.
@discardableResult
func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: UInt32, x: CGFloat = 70, y: CGFloat,
          width: CGFloat = 940, align: CTTextAlignment = .center, kern: CGFloat = 0) -> CGFloat {
    let fs = CTFramesetterCreateWithAttributedString(attributed(s, size, weight, color, align, kern))
    let size = CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRange(), nil, CGSize(width: width, height: 5000), nil)
    let h = ceil(size.height)
    CTFrameDraw(CTFramesetterCreateFrame(fs, CFRange(), CGPath(rect: R(x, y, width, h), transform: nil), nil), ctx)
    return h
}

func textWidth(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight) -> CGFloat {
    CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed(s, size, weight, white, .left, 0)), nil, nil, nil))
}

func roundRect(_ r: CGRect, _ radius: CGFloat, fill: UInt32? = nil, stroke: UInt32? = nil, lineWidth: CGFloat = 4) {
    let path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
    if let fill { ctx.addPath(path); ctx.setFillColor(rgb(fill)); ctx.fillPath() }
    if let stroke { ctx.addPath(path); ctx.setStrokeColor(rgb(stroke)); ctx.setLineWidth(lineWidth); ctx.strokePath() }
}

/// An element that rises and fades in at `delay` seconds into the scene.
func el(_ t: Double, _ delay: Double, rise: CGFloat = 50, _ draw: () -> Void) {
    let p = easeOut(clamp((t - delay) / 0.4))
    guard p > 0 else { return }
    ctx.saveGState()
    ctx.setAlpha(CGFloat(p) * sceneAlpha)
    ctx.translateBy(x: 0, y: -CGFloat(1 - p) * rise)
    draw()
    ctx.restoreGState()
}

func wordmark(_ color: UInt32) {
    ctx.saveGState()
    ctx.setAlpha(sceneAlpha)
    let w = textWidth("Tuelang", 58, .bold)
    let x = (CGFloat(W) - w - 24) / 2
    text("Tuelang", 58, .bold, color, x: x, y: 190, width: w + 10, align: .left)
    ctx.setFillColor(rgb(orange))
    ctx.fillEllipse(in: R(x + w + 10, 238, 16, 16))
    ctx.restoreGState()
}

func pill(_ label: String, y: CGFloat, size: CGFloat, fill: UInt32?, stroke: UInt32?, color: UInt32) {
    let w = textWidth(label, size, .bold) + 90
    let h = size * 2.2
    roundRect(R((CGFloat(W) - w) / 2, y, w, h), h / 2, fill: fill, stroke: stroke)
    text(label, size, .bold, color, x: 0, y: y + (h - size * 1.25) / 2, width: CGFloat(W))
}

func check(x: CGFloat, y: CGFloat) {
    ctx.setFillColor(rgb(lime))
    ctx.fillEllipse(in: R(x, y, 92, 92))
    ctx.setStrokeColor(rgb(dark))
    ctx.setLineWidth(10)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: x + 26, y: CGFloat(H) - y - 48))
    ctx.addLine(to: CGPoint(x: x + 41, y: CGFloat(H) - y - 64))
    ctx.addLine(to: CGPoint(x: x + 68, y: CGFloat(H) - y - 30))
    ctx.strokePath()
}

func bubble(_ s: String, x: CGFloat, y: CGFloat, fill: UInt32) {
    let w = textWidth(s, 66, .bold) + 110
    roundRect(R(x, y, w, 170), 48, fill: fill)
    text(s, 66, .bold, dark, x: x, y: y + 44, width: w)
}

// MARK: - Scenes

struct Scene {
    let start: Double
    let end: Double
    let bg: UInt32
    let draw: (Double) -> Void
}

let scenes: [Scene] = [
    // "Want to order coffee in Berlin by February?"
    Scene(start: 0, end: 3.5, bg: lime) { t in
        wordmark(dark)
        el(t, 0.1) { text("BERLIN · FEBRUARY 2027", 34, .semibold, dark, y: 560, kern: 5) }
        el(t, 0.3) { text("Einen Kaffee, bitte.", 124, .heavy, dark, y: 660) }
        el(t, 0.9) { text("Order coffee in Berlin by February?", 52, .medium, dark, y: 1030) }
        el(t, 1.6) { text("☕️", 130, .regular, dark, y: 1170) }
    },
    // "Tuelang's A1 German cohort starts twelfth, and you start from zero."
    Scene(start: 3.5, end: 8.5, bg: dark) { t in
        wordmark(white)
        el(t, 0.1) { text("LIVE ONLINE COURSE", 34, .semibold, orange, y: 600, kern: 5) }
        el(t, 0.3) { text("A1 German cohort", 124, .heavy, white, y: 680) }
        el(t, 1.4) { pill("Starts Tue · 12 Jan 2027", y: 1060, size: 48, fill: orange, stroke: nil, color: dark) }
        el(t, 2.9) { text("From scratch. No German needed.", 46, .medium, gray, y: 1240) }
    },
    // "Eight weeks of live classes, twice a week, with only ten students, plus a speaking club every Friday."
    Scene(start: 8.5, end: 15.5, bg: light) { t in
        wordmark(dark)
        el(t, 0.1) { text("8 weeks. Live.", 110, .heavy, dark, y: 520) }
        let cards = [("2× a week", "90-min live classes", 1.6), ("10 max", "students per cohort", 2.7), ("Fridays", "2-hour speaking club", 4.1)]
        for (i, card) in cards.enumerated() {
            let y = 720 + CGFloat(i) * 180
            el(t, card.2) {
                roundRect(R(90, y, 900, 150), 36, fill: white)
                text(card.0, 54, .heavy, dark, x: 140, y: y + 42, width: 330, align: .left)
                text(card.1, 40, .medium, gray, x: 480, y: y + 50, width: 480, align: .left)
            }
        }
        el(t, 5.4) { text("Tue & Thu · 7:00 PM CET", 42, .semibold, teal, y: 1290) }
    },
    // "You speak from the very first session, and a real teacher corrects what actually matters."
    Scene(start: 15.5, end: 21.5, bg: teal) { t in
        wordmark(white)
        el(t, 0.2) {
            bubble("Ich heiße…", x: 90, y: 600, fill: white)
            text("your first sentence", 32, .medium, white, x: 110, y: 790, width: 600, align: .left)
        }
        el(t, 2.3) {
            let w = textWidth("Gut, aber…", 66, .bold) + 110
            bubble("Gut, aber…", x: 990 - w, y: 880, fill: orange)
            text("the correction that sticks", 32, .medium, white, x: 380, y: 1070, width: 590, align: .right)
        }
        el(t, 3.8) { text("Speak from day one.\nA real teacher, not an algorithm.", 50, .bold, white, y: 1190) }
    },
    // "By the end, you'll hold a five-minute conversation, read menus and signs, and write simple messages."
    Scene(start: 21.5, end: 27.5, bg: light) { t in
        wordmark(dark)
        el(t, 0.1) { text("In 8 weeks you'll…", 96, .heavy, dark, y: 540) }
        let rows = [("Hold a 5-minute conversation", 1.0), ("Read menus, signs & headlines", 2.7), ("Write simple messages", 4.1)]
        for (i, row) in rows.enumerated() {
            let y = 780 + CGFloat(i) * 170
            el(t, row.1) {
                check(x: 110, y: y)
                text(row.0, 52, .semibold, dark, x: 240, y: y + 14, width: 760, align: .left)
            }
        }
    },
    // "And if you want, the cohort finishes with three days in Berlin, together."
    Scene(start: 27.5, end: 32.5, bg: dark) { t in
        wordmark(white)
        el(t, 0.2) { text("OPTIONAL · AFTER THE 8 WEEKS", 34, .semibold, orange, y: 580, kern: 5) }
        el(t, 2.0) { text("3 days in Berlin.", 124, .heavy, white, y: 660) }
        el(t, 3.0) { text("Friday to Sunday, with your cohort.", 48, .medium, white, y: 900) }
        el(t, 3.6) { text("Priced separately.", 38, .medium, gray, y: 980) }
        el(t, 3.8) { text("🇩🇪", 120, .regular, white, y: 1090) }
    },
    // "Founding price: three hundred ninety-nine euros, fully refundable before we start."
    Scene(start: 32.5, end: 37.5, bg: lime) { t in
        wordmark(dark)
        el(t, 0.1) { text("FOUNDING COHORT PRICE", 34, .semibold, dark, y: 560, kern: 5) }
        el(t, 0.5, rise: 80) { text("€399", 270, .heavy, dark, y: 620) }
        el(t, 1.8) {
            ctx.setAlpha(0.55 * sceneAlpha)
            text("€551", 72, .bold, dark, y: 960)
            let w = textWidth("€551", 72, .bold)
            ctx.setStrokeColor(rgb(dark))
            ctx.setLineWidth(7)
            ctx.move(to: CGPoint(x: (CGFloat(W) - w) / 2 - 10, y: CGFloat(H) - 1004))
            ctx.addLine(to: CGPoint(x: (CGFloat(W) + w) / 2 + 10, y: CGFloat(H) - 1004))
            ctx.strokePath()
        }
        el(t, 2.4) { text("Full refund before the start", 48, .semibold, dark, y: 1110) }
        el(t, 3.4) { text("or 2 × €199.50, no fees", 40, .medium, dark, y: 1185) }
    },
    // "Only ten seats. Apply now at tuelang dot com."
    Scene(start: 37.5, end: 42, bg: dark) { t in
        wordmark(white)
        el(t, 0.1) { text("Only 10 seats.", 124, .heavy, white, y: 600) }
        el(t, 1.0) { text("Apply now at", 48, .medium, gray, y: 900) }
        el(t, 1.5, rise: 70) { text("tuelang.com", 116, .heavy, orange, y: 965) }
        el(t, 2.4) { pill("Starts 12 January 2027", y: 1180, size: 42, fill: nil, stroke: white, color: white) }
    },
]
let duration = scenes.last!.end

func renderFrame(at time: Double) {
    let i = scenes.lastIndex { time >= $0.start } ?? 0
    let scene = scenes[i]
    let t = time - scene.start
    let full = CGRect(x: 0, y: 0, width: W, height: H)

    // Background: crossfade from the previous scene's colour.
    let fade = clamp(t / 0.3)
    if i > 0 && fade < 1 {
        ctx.setFillColor(rgb(scenes[i - 1].bg))
        ctx.fill(full)
    }
    ctx.setFillColor(rgb(scene.bg, CGFloat(i > 0 ? easeOut(fade) : 1)))
    ctx.fill(full)

    // Content fades out in the last moment of each scene (except the final one).
    sceneAlpha = i == scenes.count - 1 ? 1 : CGFloat(clamp((scene.end - time) / 0.2))
    scene.draw(t)

    // Thin progress bar along the bottom of the safe band.
    let progress = CGFloat(time / duration)
    ctx.setFillColor(rgb(scene.bg == dark || scene.bg == teal ? white : dark, 0.15))
    ctx.fill(R(90, 1400, 900, 6))
    ctx.setFillColor(rgb(orange))
    ctx.fill(R(90, 1400, 900 * progress, 6))
}

// MARK: - Video

let silentURL = outDir.appendingPathComponent(".video-only.mp4")
let musicURL = outDir.appendingPathComponent(".music.caf")
let finalURL = outDir.appendingPathComponent(outputName)
for url in [silentURL, musicURL, finalURL] { try? FileManager.default.removeItem(at: url) }

let writer = try! AVAssetWriter(outputURL: silentURL, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: W, AVVideoHeightKey: H,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 10_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H,
])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

let previewTimes: Set<Int> = Set(scenes.map { Int(($0.end - 0.6) * Double(fps)) })
let frameCount = Int(duration * Double(fps))
for f in 0..<frameCount {
    while !input.isReadyForMoreMediaData { usleep(2000) }
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
    let buffer = pb!
    CVPixelBufferLockBaseAddress(buffer, [])
    ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: W, height: H, bitsPerComponent: 8,
                    bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    renderFrame(at: Double(f) / Double(fps))
    if let previewDir, previewTimes.contains(f), let image = ctx.makeImage() {
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: previewDir.appendingPathComponent(String(format: "frame-%04d.png", f)))
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: CMTimeScale(fps)))
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
print("video frames: \(frameCount), status \(writer.status.rawValue)")

// MARK: - Music: soft pad, bass, kick and hat at 112 BPM

let rate = 44_100.0
let n = Int(duration * rate)
var left = [Float](repeating: 0, count: n), right = [Float](repeating: 0, count: n)
let beat = 60.0 / 112
func hz(_ midi: Double) -> Double { 440 * pow(2, (midi - 69) / 12) }
let chords: [[Double]] = [[48, 55, 64, 71], [45, 52, 60, 67], [41, 48, 57, 64], [43, 50, 59, 62]] // Cmaj7 Am7 Fmaj7 G
let chordLength = beat * 8
var noise = SystemRandomNumberGenerator()
var lastNoise: Float = 0
for i in 0..<n {
    let t = Double(i) / rate
    let ci = Int(t / chordLength) % chords.count
    let ct = t.truncatingRemainder(dividingBy: chordLength)
    let env = min(1, ct / 0.6) * min(1, (chordLength - ct) / 0.4)
    var l = 0.0, r = 0.0
    for note in chords[ci].dropFirst() {
        let f = hz(note + 12)
        l += sin(2 * .pi * f * 0.998 * t) * 0.05 * env
        r += sin(2 * .pi * f * 1.002 * t) * 0.05 * env
    }
    // Bass on beats 1 and 3.
    let bt = t.truncatingRemainder(dividingBy: beat * 2)
    let bass = sin(2 * .pi * hz(chords[ci][0] - 12) * t) * 0.16 * exp(-bt * 3)
    // Kick on every beat.
    let kt = t.truncatingRemainder(dividingBy: beat)
    let kick = sin(2 * .pi * (50 * kt + 70 / 30 * (1 - exp(-kt * 30)))) * 0.28 * exp(-kt * 14)
    // Hat on the off-beats (high-passed noise).
    let ht = (t + beat / 2).truncatingRemainder(dividingBy: beat)
    let white = Float.random(in: -1...1, using: &noise)
    let hat = Double(white - lastNoise) * 0.03 * exp(-ht * 70)
    lastNoise = white
    let master = min(1, t / 1.5) * min(1, (duration - t) / 2.5)
    left[i] = Float((l + bass + kick + hat) * master)
    right[i] = Float((r + bass + kick + hat) * master)
}
let peak = max(left.map(abs).max()!, right.map(abs).max()!)
let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
pcm.frameLength = AVAudioFrameCount(n)
for i in 0..<n {
    pcm.floatChannelData![0][i] = left[i] / peak * 0.7
    pcm.floatChannelData![1][i] = right[i] / peak * 0.7
}
do {
    let file = try AVAudioFile(forWriting: musicURL, settings: format.settings)
    try file.write(from: pcm)
}

// MARK: - Mux

let video = AVURLAsset(url: silentURL), music = AVURLAsset(url: musicURL)
let comp = AVMutableComposition()
let range = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
try! comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
    .insertTimeRange(range, of: video.tracks(withMediaType: .video)[0], at: .zero)
try! comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
    .insertTimeRange(range, of: music.tracks(withMediaType: .audio)[0], at: .zero)
let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality)!
export.outputURL = finalURL
export.outputFileType = .mp4
let exported = DispatchSemaphore(value: 0)
export.exportAsynchronously { exported.signal() }
exported.wait()
print("export status \(export.status.rawValue) \(export.error?.localizedDescription ?? "")")
for url in [silentURL, musicURL] { try? FileManager.default.removeItem(at: url) }
print("wrote \(finalURL.path)")
