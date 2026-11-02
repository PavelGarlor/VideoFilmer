import CoreImage
import CoreImage.CIFilterBuiltins

/// Lays out the camera and the AI video inside the output frame.
enum Compositor {
    /// Rects use top-left origin coordinates (like the UI); `compose` flips them for Core Image.
    struct Layout {
        var video: CGRect?
        var cam: CGRect?
        var camRadius: CGFloat = 0
    }

    static func layout(_ s: RenderSettings, size: CGSize, kind: LayoutKind? = nil) -> Layout {
        let W = size.width, H = size.height
        let full = CGRect(origin: .zero, size: size)
        switch kind ?? s.layout {
        case .camTop:
            let ch = (H * s.split).rounded()
            return Layout(video: CGRect(x: 0, y: ch, width: W, height: H - ch), cam: CGRect(x: 0, y: 0, width: W, height: ch))
        case .videoTop:
            let ch = (H * s.split).rounded()
            return Layout(video: CGRect(x: 0, y: 0, width: W, height: H - ch), cam: CGRect(x: 0, y: H - ch, width: W, height: ch))
        case .side:
            let cw = (W * s.split).rounded()
            return Layout(video: CGRect(x: cw, y: 0, width: W - cw, height: H), cam: CGRect(x: 0, y: 0, width: cw, height: H))
        case .pip:
            let base = min(W, H)
            let w = (base * s.pipSize).rounded()
            let h = s.pipShape == .tall ? (w * 1.25).rounded() : w
            let margin = (base * 0.04).rounded()
            let x = s.corner.isLeft ? margin : W - w - margin
            let y = s.corner.isTop ? margin : H - h - margin
            return Layout(video: full, cam: CGRect(x: x, y: y, width: w, height: h), camRadius: s.pipShape == .circle ? w / 2 : w * 0.08)
        case .voiceOnly:
            return Layout(video: full, cam: nil)
        case .camOnly:
            return Layout(video: nil, cam: full)
        }
    }

    static func compose(cam: CIImage?, video: CIImage?, settings s: RenderSettings, size: CGSize) -> CIImage {
        let full = CGRect(origin: .zero, size: size)
        let flip = { (r: CGRect) in CGRect(x: r.minX, y: size.height - r.maxY, width: r.width, height: r.height) }
        let l = layout(s, size: size)
        var out = CIImage(color: .black).cropped(to: full)

        if let r = l.video.map(flip) {
            let layer = video.map { fill($0, in: r, cover: !s.fitWholeVideo) } ?? placeholder("Load your AI video", in: r)
            out = layer.composited(over: out)
        }
        if let r = l.cam.map(flip) {
            let layer = cam.map { fill($0, in: r, cover: true, mirror: s.mirror) } ?? placeholder("Camera", in: r)
            if l.camRadius > 0 {
                let border = roundedRect(r.insetBy(dx: -6, dy: -6), radius: l.camRadius + 6, color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.9))
                out = border.composited(over: out)
                out = layer.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: out,
                    kCIInputMaskImageKey: roundedRect(r, radius: l.camRadius, color: .white),
                ])
            } else {
                out = layer.composited(over: out)
            }
        }
        return out.cropped(to: full)
    }

    // MARK: - Helpers

    private static func fill(_ src: CIImage, in r: CGRect, cover: Bool, mirror: Bool = false) -> CIImage {
        let covered = scaled(src, in: r, cover: true, mirror: mirror).cropped(to: r)
        if cover { return covered }
        // Whole video visible, with a blurred, darkened copy filling the bars.
        let bg = covered.clampedToExtent().applyingGaussianBlur(sigma: 40).cropped(to: r)
        let dim = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.45)).cropped(to: r)
        return scaled(src, in: r, cover: false, mirror: mirror).cropped(to: r).composited(over: dim.composited(over: bg))
    }

    private static func scaled(_ src: CIImage, in r: CGRect, cover: Bool, mirror: Bool) -> CIImage {
        var img = src
        if mirror { img = img.transformed(by: CGAffineTransform(scaleX: -1, y: 1)) }
        let e = img.extent
        let k = cover ? max(r.width / e.width, r.height / e.height) : min(r.width / e.width, r.height / e.height)
        return img
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: k, y: k))
            .transformed(by: CGAffineTransform(translationX: r.midX - e.width * k / 2, y: r.midY - e.height * k / 2))
    }

    private static func roundedRect(_ r: CGRect, radius: CGFloat, color: CIColor) -> CIImage {
        let f = CIFilter.roundedRectangleGenerator()
        f.extent = r
        f.radius = Float(radius)
        f.color = color
        return f.outputImage?.cropped(to: r) ?? CIImage.empty()
    }

    // Only touched from the engine's render queue.
    private static var labelCache: [String: CIImage] = [:]

    private static func placeholder(_ text: String, in r: CGRect) -> CIImage {
        let bg = CIImage(color: CIColor(red: 0.11, green: 0.12, blue: 0.15)).cropped(to: r)
        let fontSize = (min(r.width, r.height) * 0.07).rounded()
        let key = "\(text)|\(fontSize)"
        let label: CIImage
        if let cached = labelCache[key] {
            label = cached
        } else {
            let f = CIFilter.textImageGenerator()
            f.text = text
            f.fontName = "HelveticaNeue-Medium"
            f.fontSize = Float(fontSize)
            f.scaleFactor = 1
            guard let raw = f.outputImage else { return bg }
            // The generator draws black text; repaint it light gray, keeping its alpha.
            label = raw.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: 0.55, y: 0.58, z: 0.66, w: 0),
            ])
            labelCache[key] = label
        }
        let e = label.extent
        let placed = label.transformed(by: CGAffineTransform(translationX: r.midX - e.midX, y: r.midY - e.midY))
        return placed.composited(over: bg).cropped(to: r)
    }
}
