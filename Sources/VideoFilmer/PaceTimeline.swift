import SwiftUI

/// How comfortable a speaking speed is.
enum Pace {
    static func color(_ wpm: Double) -> Color {
        switch wpm {
        case ..<110: Color(red: 0.4, green: 0.65, blue: 1)
        case ..<170: Color(red: 0.35, green: 0.82, blue: 0.48)
        case ..<195: Color.orange
        default: Color.red
        }
    }

    static func label(_ wpm: Double) -> String {
        switch wpm {
        case ..<110: "slow"
        case ..<170: "comfortable"
        case ..<195: "fast"
        default: "too fast"
        }
    }
}

/// The script's lines laid along the AI video. Drag the edges between lines to give a line
/// more or less time; the colour says how fast that line has to be read.
struct PaceTimeline: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var prompter: PrompterController
    @State private var selected: Int? // source row
    @State private var drag: (index: Int, time: Double)?

    private let thumbHeight: CGFloat = 26
    private let blockHeight: CGFloat = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let duration = model.videoDuration, !prompter.script.lines.isEmpty {
                track(duration: duration)
                    .disabled(model.isBusy)
            } else {
                Text(model.videoDuration == nil
                     ? "Load a video to see each line of the script on its timeline."
                     : "Add a script to see the pace of each line.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: thumbHeight + blockHeight + 6)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(white: 0.09))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Text("Pace").font(.subheadline.weight(.semibold))
            if let (i, block) = selectedBlock {
                Text("Line \(i + 1) · \(Int(block.wpm.rounded())) wpm · \(Pace.label(block.wpm))")
                    .font(.caption)
                    .foregroundStyle(Pace.color(block.wpm))
                Spacer()
                Group {
                    Button { resize(i, by: 1.12) } label: { Label("Slower", systemImage: "tortoise") }
                    Button { resize(i, by: 0.88) } label: { Label("Faster", systemImage: "hare") }
                    Button { model.editingLine = block.line.sourceIndex } label: { Label("Edit text", systemImage: "pencil") }
                }
                .controlSize(.small)
                .disabled(model.isBusy)
                Button { selected = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            } else {
                legend
                Spacer()
                Text("Drag between lines to give one more or less time · click to select · double-click to edit")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(height: 22)
    }

    private var legend: some View {
        HStack(spacing: 8) {
            ForEach([(100.0, "slow"), (150.0, "comfortable"), (180.0, "fast"), (210.0, "too fast")], id: \.1) { wpm, name in
                HStack(spacing: 3) {
                    Circle().fill(Pace.color(wpm)).frame(width: 7, height: 7)
                    Text(name).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Track

    private func track(duration: Double) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            let blocks = shownBlocks
            let x = { (t: Double) in width * CGFloat(t / duration) }

            ZStack(alignment: .topLeading) {
                thumbnails(width: width)

                ForEach(Array(blocks.enumerated()), id: \.offset) { i, block in
                    blockView(block, selected: block.line.sourceIndex == selected)
                        .frame(width: max(3, x(block.end) - x(block.start) - 2), height: blockHeight)
                        .offset(x: x(block.start) + 1, y: thumbHeight + 4)
                        .onTapGesture(count: 2) {
                            selected = block.line.sourceIndex
                            model.editingLine = block.line.sourceIndex
                        }
                        .onTapGesture {
                            selected = block.line.sourceIndex
                            prompter.jump(to: block.line.firstWord)
                        }
                }

                ForEach(Array(blocks.enumerated()), id: \.offset) { i, block in
                    handle(active: drag?.index == i)
                        .offset(x: x(block.start) - 7, y: thumbHeight + 2)
                        .gesture(DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let base = baseBlocks
                                guard base.indices.contains(i) else { return }
                                let lo = i > 0 ? base[i - 1].start + 0.3 : 0
                                let hi = (i + 1 < base.count ? base[i + 1].start : duration) - 0.3
                                let t = base[i].start + Double(value.translation.width / width) * duration
                                drag = (i, min(max(t, lo), hi))
                            }
                            .onEnded { _ in
                                guard let d = drag else { return }
                                var starts = currentStarts()
                                starts[baseBlocks[d.index].line.sourceIndex] = d.time
                                drag = nil
                                model.setLineStarts(starts)
                            })
                        .onHover { inside in
                            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                        }
                }

                if model.phase == .recording || model.phase == .rehearsing {
                    TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                        let t = model.engine.player.currentTime().seconds
                        Rectangle().fill(Color.red)
                            .frame(width: 2, height: thumbHeight + blockHeight + 6)
                            .offset(x: x(t.isFinite ? t : 0))
                    }
                    .allowsHitTesting(false)
                }
            }
        }
        .frame(height: thumbHeight + blockHeight + 6)
    }

    private func thumbnails(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(model.thumbnails.enumerated()), id: \.offset) { _, image in
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width / CGFloat(max(1, model.thumbnails.count)), height: thumbHeight)
                    .clipped()
            }
        }
        .frame(width: width, height: thumbHeight, alignment: .leading)
        .background(Color(white: 0.15))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .opacity(0.75)
    }

    private func blockView(_ block: PaceBlock, selected: Bool) -> some View {
        let color = Pace.color(block.wpm)
        let isCurrent = prompter.current >= block.line.firstWord && prompter.current < block.line.firstWord + block.line.wordCount
        return RoundedRectangle(cornerRadius: 6)
            .fill(color.opacity(isCurrent ? 0.42 : 0.26))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(selected ? Color.white : color.opacity(0.75), lineWidth: selected ? 2 : 1)
            )
            .overlay(alignment: .leading) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(block.line.body).font(.caption2).lineLimit(1)
                    Text("\(Int(block.wpm.rounded())) wpm").font(.caption2.weight(.bold)).foregroundStyle(color)
                }
                .padding(.horizontal, 6)
            }
            .clipped()
            .contentShape(Rectangle())
            .help("\(block.line.body)\n\(Int(block.wpm.rounded())) words/min (\(Pace.label(block.wpm))) · \(String(format: "%.1f", block.end - block.start)) s")
    }

    private func handle(active: Bool) -> some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Color.white.opacity(active ? 0.95 : 0.4))
            .frame(width: 3, height: blockHeight + 4)
            .padding(.horizontal, 5.5)
            .contentShape(Rectangle())
    }

    // MARK: - Data

    private var baseBlocks: [PaceBlock] { model.paceBlocks }

    /// Blocks with the edge being dragged moved, before it's committed.
    private var shownBlocks: [PaceBlock] {
        var blocks = baseBlocks
        if let d = drag, blocks.indices.contains(d.index) {
            blocks[d.index].start = d.time
            if d.index > 0 { blocks[d.index - 1].end = d.time }
        }
        return blocks
    }

    private var selectedBlock: (Int, PaceBlock)? {
        guard let selected else { return nil }
        let blocks = shownBlocks
        guard let i = blocks.firstIndex(where: { $0.line.sourceIndex == selected }) else { return nil }
        return (i, blocks[i])
    }

    private func currentStarts() -> [Int: Double] {
        Dictionary(uniqueKeysWithValues: baseBlocks.map { ($0.line.sourceIndex, $0.start) })
    }

    /// Gives line `i` `factor` times its current time, taking it from (or giving it to) the next line.
    private func resize(_ i: Int, by factor: Double) {
        let blocks = baseBlocks
        guard blocks.indices.contains(i), let duration = model.videoDuration else { return }
        let b = blocks[i]
        let length = b.end - b.start
        var starts = currentStarts()
        if i + 1 < blocks.count {
            let limit = (i + 2 < blocks.count ? blocks[i + 2].start : duration) - 0.3
            starts[blocks[i + 1].line.sourceIndex] = min(limit, max(b.start + 0.3, b.start + length * factor))
        } else if i > 0 {
            let lo = blocks[i - 1].start + 0.3
            starts[b.line.sourceIndex] = max(lo, min(b.end - 0.3, b.end - length * factor))
        } else {
            return
        }
        model.setLineStarts(starts)
    }
}

/// Edits one line of the script in place, showing how fast it will have to be read.
struct LineEditor: View {
    @EnvironmentObject var model: AppModel
    let line: ScriptLine
    /// Time the line gets in the video, if known.
    let seconds: Double?
    @State private var text: String
    @FocusState private var focused: Bool

    init(line: ScriptLine, seconds: Double?) {
        self.line = line
        self.seconds = seconds
        _text = State(initialValue: line.body)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Edit line").font(.headline)
                Spacer()
                if let seconds, seconds > 0 {
                    let words = ParsedScript.parse(text, fontSize: 12).words.count
                    let wpm = Double(words) / seconds * 60
                    Text("\(words) words in \(String(format: "%.1f", seconds)) s · \(Int(wpm.rounded())) wpm · \(Pace.label(wpm))")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Pace.color(wpm))
                }
            }
            TextField("Line", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 20))
                .lineLimit(1...4)
                .focused($focused)
                .onSubmit(save)
            HStack {
                Text("Too fast? Give the line more time on the Pace timeline, or cut a few words. Empty the line to delete it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.editingLine = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(maxWidth: 900)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 20)
        .padding(14)
        .onAppear { focused = true }
    }

    private func save() {
        model.editLine(sourceIndex: line.sourceIndex, body: text)
        model.editingLine = nil
    }
}
