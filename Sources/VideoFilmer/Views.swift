import AVFoundation
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 300, ideal: 350, max: 440)
        } detail: {
            GeometryReader { geo in
                VStack(spacing: 0) {
                    PrompterPane(prompter: model.prompter)
                        .frame(height: geo.size.height * model.settings.prompterHeight)
                    Divider()
                    PaceTimeline(prompter: model.prompter)
                    Divider()
                    StageView()
                    Divider()
                    ControlsBar(stats: model.stats)
                }
            }
            .background(Color.black)
            .overlay {
                if let review = model.review {
                    ReviewView(review: review).id(review.take.url)
                }
            }
        }
        .sheet(item: $model.cameraGuide) { tab in
            CameraGuideView(tab: tab).environmentObject(model)
        }
        .onChange(of: model.phase) { _, phase in
            // Hide the sidebar while recording so the teleprompter and preview get the space.
            withAnimation { columns = phase == .recording ? .detailOnly : .all }
        }
    }
}

struct PrompterPane: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var prompter: PrompterController

    var body: some View {
        PrompterTextView(script: prompter.script, revision: prompter.revision, current: prompter.current,
                         onJump: { prompter.jump(to: $0) },
                         onDoubleClick: { index in
                             guard !model.isBusy,
                                   let line = prompter.script.lines.first(where: { NSLocationInRange(index, $0.range) }) else { return }
                             model.editingLine = line.sourceIndex
                         })
        .overlay(alignment: .top) {
            if let row = model.editingLine, let line = prompter.script.lines.first(where: { $0.sourceIndex == row }) {
                LineEditor(line: line, seconds: model.paceBlocks.first { $0.line.sourceIndex == row }.map { $0.end - $0.start })
                    .id(row)
            }
        }
    }
}

struct StageView: View {
    @EnvironmentObject var model: AppModel
    @State private var dropTargeted = false

    var body: some View {
        ZStack {
            PreviewLayerView(layer: model.engine.displayLayer)
            if let n = model.countdownValue {
                Text("\(n)")
                    .font(.system(size: 160, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(radius: 20)
            }
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.red, style: StrokeStyle(lineWidth: 3, dash: [10]))
                    .background(Color.red.opacity(0.08))
                    .overlay(Text("Drop the video here").font(.title2))
                    .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, !model.isBusy else { return false }
            model.loadVideo(url)
            return true
        } isTargeted: { dropTargeted = $0 }
    }
}

struct ControlsBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var stats: LiveStats

    var body: some View {
        HStack(spacing: 12) {
            switch model.phase {
            case .idle:
                Button { model.startTake(record: true) } label: { Label("Record", systemImage: "record.circle") }
                    .keyboardShortcut("r", modifiers: .command)
                    .tint(.red)
                    .buttonStyle(.borderedProminent)
                Button { model.startTake(record: false) } label: { Label("Rehearse", systemImage: "play") }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            case .countdown, .rehearsing, .recording:
                Button { model.stopTake() } label: { Label("Stop", systemImage: "stop.fill") }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.borderedProminent)
                Button("") { model.stopTake() }
                    .keyboardShortcut("r", modifiers: .command)
                    .hidden()
                    .frame(width: 0)
            case .saving:
                ProgressView().controlSize(.small)
            case .reviewing:
                EmptyView()
            }

            HStack(spacing: 6) {
                if model.phase == .recording { Circle().fill(.red).frame(width: 8, height: 8) }
                Text(timerText).monospacedDigit()
            }
            .frame(minWidth: 110, alignment: .leading)

            MicMeter(db: stats.micLevel)

            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Text("⌘R record/stop · ⇧⌘R rehearse · Esc stop · click a word to jump")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var timerText: String {
        let elapsed = model.phase == .recording || model.phase == .rehearsing ? stats.elapsed : 0
        if let d = model.videoDuration { return "\(formatTime(elapsed)) / \(formatTime(d))" }
        return formatTime(elapsed)
    }
}

struct MicMeter: View {
    let db: Float

    var body: some View {
        let level = CGFloat(max(0, min(1, (db + 60) / 60)))
        ZStack(alignment: .leading) {
            Capsule().fill(Color.gray.opacity(0.25))
            Capsule().fill(level > 0.9 ? Color.red : level > 0.75 ? Color.yellow : Color.green)
                .frame(width: 90 * level)
        }
        .frame(width: 90, height: 7)
        .help("Microphone level")
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var model: AppModel

    private static let languages: [(String, String)] = [
        ("en-US", "English (US)"), ("en-GB", "English (UK)"), ("es-ES", "Español (España)"),
        ("es-MX", "Español (Latinoamérica)"), ("fr-FR", "Français"), ("de-DE", "Deutsch"),
        ("it-IT", "Italiano"), ("pt-BR", "Português (Brasil)"), ("pt-PT", "Português (Portugal)"),
        ("nl-NL", "Nederlands"),
    ]

    var body: some View {
        Form {
            Section {
                Picker("Camera", selection: $model.settings.cameraID) {
                    Text("Mac's default").tag(String?.none)
                    ForEach(model.cameras, id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.uniqueID)) }
                }
                Picker("Microphone", selection: $model.settings.micID) {
                    Text("Mac's default").tag(String?.none)
                    ForEach(model.microphones, id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.uniqueID)) }
                }
                Text("USB cameras, an iPhone (Continuity Camera) and external mics show up here as soon as they're plugged in.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button { model.cameraGuide = .iPhone } label: { Label("Use your iPhone as a camera…", systemImage: "iphone") }
                    Button { model.cameraGuide = .camera } label: { Label("Other cameras…", systemImage: "camera") }
                }
                .controlSize(.small)
            } header: {
                Text("Camera & mic")
            }

            Section("1 · Sources") {
                HStack {
                    Button("Choose AI video…") { model.chooseVideo() }
                    Spacer()
                }
                Text(model.videoInfo).font(.caption).foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Script")
                        Spacer()
                        Button("Load from file…") { model.chooseScript() }.controlSize(.small)
                    }
                    TextEditor(text: $model.settings.script)
                        .font(.system(size: 12))
                        .frame(minHeight: 170)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Text("Start a line with [m:ss] to pin it to that moment of the video. Notes in [brackets] or (parentheses) are shown small and not read.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("2 · Layout") {
                Picker("Format", selection: $model.settings.aspect) {
                    ForEach(AspectKind.allCases) { Text($0.label).tag($0) }
                }
                LayoutGrid()
                if model.settings.layout.usesSplit {
                    Slider(value: $model.settings.split, in: 0.25...0.75) {
                        Text("My share \(Int(model.settings.split * 100))%")
                    }
                }
                if model.settings.layout == .pip {
                    Picker("Corner", selection: $model.settings.corner) {
                        ForEach(Corner.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Shape", selection: $model.settings.pipShape) {
                        ForEach(PipShape.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Slider(value: $model.settings.pipSize, in: 0.2...0.6) { Text("Size") }
                }
                if model.settings.layout != .camOnly {
                    Toggle("Show the whole AI video (blurred bars)", isOn: $model.settings.fitWholeVideo)
                }
                if model.settings.layout != .voiceOnly {
                    Toggle("Mirror my camera", isOn: $model.settings.mirrorCamera)
                }
            }

            Section("3 · Teleprompter") {
                Picker("Highlight follows", selection: $model.settings.promptMode) {
                    ForEach(PromptMode.allCases) { Text($0.label).tag($0) }
                }
                PromptSummary(prompter: model.prompter)
                if model.settings.promptMode == .speed {
                    Slider(value: $model.settings.wpm, in: 80...240, step: 5) {
                        Text("\(Int(model.settings.wpm)) words/min")
                    }
                }
                if model.settings.promptMode == .voice {
                    Picker("Script language", selection: $model.settings.language) {
                        ForEach(Self.languages, id: \.0) { Text($0.1).tag($0.0) }
                    }
                }
                Slider(value: $model.settings.fontSize, in: 22...80, step: 1) { Text("Text size") }
                Slider(value: $model.settings.prompterHeight, in: 0.2...0.75) { Text("Height") }
            }

            Section("4 · Recording") {
                Toggle("Include the AI video's sound", isOn: $model.settings.includeVideoAudio)
                Slider(value: $model.settings.videoVolume, in: 0...1) { Text("Video sound") }
                Text("Starting level for new takes. You can change your voice and the video sound on each take afterwards.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Play video audio out loud (use headphones)", isOn: $model.settings.monitorVideoAudio)
                Toggle("Also save my camera on its own", isOn: $model.settings.saveCameraSeparately)
                Text("A second file with just you, full frame at the camera's resolution, with your mic. Same start and length as the take, so it lines up in Premiere, Final Cut, DaVinci or CapCut. Saved to Movies › VideoFilmer › Camera.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Start the video from 0:00 on each take", isOn: $model.settings.restartVideo)
                Toggle("Stop when the video ends", isOn: $model.settings.stopOnVideoEnd)
                Picker("Countdown", selection: $model.settings.countdown) {
                    Text("None").tag(0)
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                }
            }

            Section {
                if model.takes.isEmpty {
                    Text("No takes yet. They're saved to Movies › VideoFilmer.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.takes) { take in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(take.url.deletingPathExtension().lastPathComponent).lineLimit(1)
                            if let d = take.duration {
                                Text(formatTime(d)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button { model.open(take) } label: { Image(systemName: "play.fill") }.help("Watch")
                        Button { model.reveal(take) } label: { Image(systemName: "folder") }.help("Show in Finder")
                        Button { model.delete(take) } label: { Image(systemName: "trash") }.help("Move to Trash")
                    }
                    .buttonStyle(.borderless)
                }
            } header: {
                HStack {
                    Text("Takes")
                    Spacer()
                    Button("Open folder") { model.openTakesFolder() }.controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(model.isBusy)
    }
}

struct PromptSummary: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var prompter: PrompterController

    var body: some View {
        Text(prompter.summary(mode: model.settings.promptMode, wpm: model.settings.wpm, videoDuration: model.videoDuration))
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

struct LayoutGrid: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            ForEach(LayoutKind.allCases) { kind in
                let selected = model.settings.layout == kind
                Button { model.settings.layout = kind } label: {
                    VStack(spacing: 6) {
                        LayoutThumb(kind: kind, settings: model.settings.render)
                        Text(kind.label)
                            .font(.caption2)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(selected ? .primary : .secondary)
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, minHeight: 92)
                    .contentShape(Rectangle())
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(selected ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: selected ? 2 : 1))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct LayoutThumb: View {
    let kind: LayoutKind
    let settings: RenderSettings

    var body: some View {
        let size = settings.aspect.size
        let k = 50 / max(size.width, size.height)
        Canvas { ctx, _ in
            let l = Compositor.layout(settings, size: size, kind: kind)
            let scale = { (r: CGRect) in CGRect(x: r.minX * k, y: r.minY * k, width: r.width * k, height: r.height * k) }
            ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width * k, height: size.height * k)), with: .color(.black))
            if let v = l.video { ctx.fill(Path(scale(v)), with: .color(Color(white: 0.4))) }
            if let c = l.cam {
                ctx.fill(Path(roundedRect: scale(c), cornerRadius: l.camRadius * k), with: .color(.orange))
            }
        }
        .frame(width: size.width * k, height: size.height * k)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}
