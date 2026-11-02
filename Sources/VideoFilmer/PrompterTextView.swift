import AppKit
import SwiftUI

/// The teleprompter text: read words dim, the current word is highlighted and kept near the top.
struct PrompterTextView: NSViewRepresentable {
    let script: ParsedScript
    let revision: Int
    let current: Int
    let onJump: (Int) -> Void
    /// Double-click: character index in the teleprompter text.
    var onDoubleClick: (Int) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = true
        scroll.backgroundColor = .black

        let tv = ClickableTextView(usingTextLayoutManager: false)
        tv.isEditable = false
        tv.isSelectable = false
        tv.drawsBackground = true
        tv.backgroundColor = .black
        tv.textContainerInset = NSSize(width: 48, height: 24)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.frame = NSRect(origin: .zero, size: scroll.contentSize)
        scroll.documentView = tv
        context.coordinator.textView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        let words = script.words
        c.textView?.onClick = { charIndex in
            if let i = words.firstIndex(where: { NSLocationInRange(charIndex, $0.range) }) { onJump(i) }
        }
        c.textView?.onDoubleClick = onDoubleClick
        if c.revision != revision { c.load(script, revision: revision, in: scroll) }
        c.highlight(current, in: scroll)
    }

    final class Coordinator {
        weak var textView: ClickableTextView?
        var revision = -1
        private var script = ParsedScript()
        private var shown = -1
        private var lastLineY: CGFloat = -1

        func load(_ script: ParsedScript, revision: Int, in scroll: NSScrollView) {
            self.script = script
            self.revision = revision
            shown = -1
            lastLineY = -1
            textView?.textStorage?.setAttributedString(script.text)
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        func highlight(_ index: Int, in scroll: NSScrollView) {
            guard index != shown, let tv = textView, let storage = tv.textStorage else { return }
            let words = script.words
            guard !words.isEmpty else { return }
            let old = max(shown, 0)
            let lo = max(0, min(old, index) - 1)
            let hi = min(words.count - 1, max(old, index) + 1)
            storage.beginEditing()
            if lo <= hi {
                for k in lo...hi {
                    let r = words[k].range
                    if k == index {
                        storage.addAttributes([.foregroundColor: PrompterStyle.currentText,
                                               .backgroundColor: PrompterStyle.currentBackground], range: r)
                    } else {
                        storage.removeAttribute(.backgroundColor, range: r)
                        storage.addAttribute(.foregroundColor, value: k < index ? PrompterStyle.spoken : PrompterStyle.upcoming, range: r)
                    }
                }
            }
            storage.endEditing()
            shown = index
            scrollToWord(min(index, words.count - 1), in: scroll)
        }

        private func scrollToWord(_ i: Int, in scroll: NSScrollView) {
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            let glyphs = lm.glyphRange(forCharacterRange: script.words[i].range, actualCharacterRange: nil)
            let y = lm.boundingRect(forGlyphRange: glyphs, in: tc).minY + tv.textContainerInset.height
            guard abs(y - lastLineY) > 1 else { return }
            lastLineY = y
            let target = max(0, y - scroll.contentView.bounds.height * 0.3)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                scroll.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: target))
            }
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
}

final class ClickableTextView: NSTextView {
    var onClick: ((Int) -> Void)?
    var onDoubleClick: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        if event.clickCount == 2 { onDoubleClick?(index) } else { onClick?(index) }
    }
}

/// Hosts the engine's preview layer.
struct PreviewLayerView: NSViewRepresentable {
    let layer: CALayer

    func makeNSView(context: Context) -> HostView {
        let v = HostView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.black.cgColor
        v.layer?.addSublayer(layer)
        v.hosted = layer
        return v
    }

    func updateNSView(_ nsView: HostView, context: Context) {}

    final class HostView: NSView {
        var hosted: CALayer?
        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hosted?.frame = bounds
            CATransaction.commit()
        }
    }
}
