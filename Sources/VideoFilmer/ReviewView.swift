import AVKit
import SwiftUI

/// Plays a take back with adjustable voice / video sound levels.
/// A fresh take can be saved, recorded again or discarded; a saved one can be re-mixed.
struct ReviewView: View {
    @EnvironmentObject var model: AppModel
    let review: AppModel.Review
    @StateObject private var playback = ReviewPlayback()

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text(review.isNew ? "Your take" : review.take.url.deletingPathExtension().lastPathComponent)
                    .font(.title3.weight(.semibold))
                if let d = review.take.duration {
                    Text(formatTime(d)).foregroundStyle(.secondary).monospacedDigit()
                }
            }

            PlayerView(player: playback.player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let mix = review.mix {
                MixControls(mix: mix, hasVideoSound: playback.hasVideoSound)
            } else {
                Text("This take was recorded before audio levels could be changed afterwards.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button {
                    playback.player.seek(to: .zero)
                    playback.player.play()
                } label: { Label("Replay", systemImage: "gobackward") }

                Spacer()

                if model.phase == .saving {
                    ProgressView().controlSize(.small)
                    Text("Saving…").foregroundStyle(.secondary)
                } else if review.isNew {
                    Button(role: .destructive) {
                        playback.player.pause()
                        model.discardReview()
                    } label: { Label("Discard", systemImage: "trash") }
                    Button {
                        playback.player.pause()
                        model.retake()
                    } label: { Label("Record again", systemImage: "arrow.counterclockwise") }
                        .keyboardShortcut("r", modifiers: .command)
                    Button {
                        playback.player.pause()
                        Task { await model.saveReview() }
                    } label: { Label("Save take", systemImage: "checkmark") }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button { model.reveal(review.take) } label: { Label("Show in Finder", systemImage: "folder") }
                    if let camera = review.mix?.cameraPath {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: camera)])
                        } label: { Label("Camera file", systemImage: "person.crop.rectangle") }
                    }
                    Button(role: .destructive) {
                        playback.player.pause()
                        model.delete(review.take)
                    } label: { Label("Move to Trash", systemImage: "trash") }
                    if review.mix != nil {
                        Button {
                            Task { await model.saveReview() }
                        } label: { Label("Save audio changes", systemImage: "checkmark") }
                            .disabled(!review.hasUnsavedMix)
                    }
                    Button("Close") {
                        playback.player.pause()
                        model.closeReview()
                    }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.large)

            if review.isNew {
                Text(review.mix?.cameraPath != nil
                     ? "Return saves (the camera-only file is saved too) · ⌘R records again"
                     : "Return saves · ⌘R records again")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.96))
        .onAppear { playback.load(review) }
        .onDisappear { playback.player.pause() }
        .onChange(of: review.mix) { _, mix in playback.apply(mix) }
    }
}

private struct MixControls: View {
    @EnvironmentObject var model: AppModel
    let mix: TakeMix
    let hasVideoSound: Bool

    var body: some View {
        HStack(spacing: 28) {
            level("My voice", systemImage: "mic.fill", value: mix.voiceVolume) { model.setReviewMix(voice: $0) }
            level("Video sound", systemImage: "music.note", value: mix.videoVolume) { model.setReviewMix(video: $0) }
                .disabled(!hasVideoSound)
                .help(hasVideoSound ? "" : "The AI video has no sound in this take.")
        }
        .frame(maxWidth: 640)
        .disabled(model.phase == .saving)
    }

    private func level(_ title: String, systemImage: String, value: Double, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage).frame(width: 120, alignment: .leading)
            Slider(value: Binding(get: { value }, set: set), in: 0...1)
            Text("\(Int((value * 100).rounded()))%").monospacedDigit().frame(width: 44, alignment: .trailing)
        }
    }
}

/// Plays the take's raw recording with the AI video's sound laid under it, so levels change live.
@MainActor
final class ReviewPlayback: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var hasVideoSound = false
    private var plan: TakeAudio.Plan?

    func load(_ review: AppModel.Review) {
        guard let mix = review.mix else {
            player.replaceCurrentItem(with: AVPlayerItem(url: review.take.url))
            player.play()
            return
        }
        Task {
            do {
                let plan = try await TakeAudio.plan(for: mix)
                self.plan = plan
                hasVideoSound = plan.videoSoundTrack != nil
                let item = AVPlayerItem(asset: plan.composition)
                item.audioMix = plan.audioMix(voice: mix.voiceVolume, video: mix.videoVolume)
                player.replaceCurrentItem(with: item)
            } catch {
                player.replaceCurrentItem(with: AVPlayerItem(url: review.take.url))
            }
            player.play()
        }
    }

    func apply(_ mix: TakeMix?) {
        guard let mix, let plan, let item = player.currentItem else { return }
        item.audioMix = plan.audioMix(voice: mix.voiceVolume, video: mix.videoVolume)
    }
}

/// AppKit's player with standard controls. (SwiftUI's VideoPlayer crashes in SwiftPM-built apps.)
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
