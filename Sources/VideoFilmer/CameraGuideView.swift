import AVFoundation
import SwiftUI

/// Step-by-step help for using an iPhone (Continuity Camera) or a real camera.
/// The status card at the top watches for the device, so you see when it worked.
struct CameraGuideView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case iPhone = "iPhone"
        case camera = "Other cameras"
        var id: String { rawValue }
    }

    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var tab: Tab = .iPhone

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 280)
            .padding(.vertical, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch tab {
                    case .iPhone: iPhoneGuide
                    case .camera: cameraGuide
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 620, height: 680)
    }

    // MARK: - iPhone

    @ViewBuilder private var iPhoneGuide: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Use your iPhone as a camera").font(.title2.bold())
            Text("Your iPhone's back camera usually looks much better than the Mac's webcam. It connects wirelessly and there's nothing to install. Apple calls this Continuity Camera.")
                .foregroundStyle(.secondary)
        }

        iPhoneStatus

        Step(number: 1, symbol: "checklist", title: "Check you have what's needed") {
            Text("An iPhone XR or newer with iOS 16 or later. This Mac already qualifies.")
            Text("Both signed in to the **same Apple Account**: on the iPhone, Settings › your name; on the Mac, System Settings › your name.")
        }
        Step(number: 2, symbol: "wifi", title: "Turn on Wi‑Fi and Bluetooth on both") {
            Text("They don't need to be on the same network, but both radios must be on. Or simply connect the iPhone to the Mac with a USB cable.")
        }
        Step(number: 3, symbol: "gearshape", title: "Turn on Continuity Camera on the iPhone") {
            Text("Settings › General › **AirPlay & Continuity** › **Continuity Camera**. It's usually on already.")
        }
        Step(number: 4, symbol: "iphone.gen3", title: "Place the iPhone near the Mac, back cameras facing you") {
            Text("**Lock it** (screen off) and keep it still on a stand, mount or a pile of books. Your eyes should be near the top of the screen, where the teleprompter is.")
            Text("Upright (portrait) suits vertical 9:16 videos; sideways suits 16:9.")
        }
        Step(number: 5, symbol: "video", title: "Choose it in VideoFilmer") {
            Text("It appears under **Camera** as “… iPhone Camera”. Use the button in the green box above, or pick it in the sidebar. The iPhone then shows that it's connected to your Mac.")
        }
        Step(number: 6, symbol: "mic", title: "Optional: use its microphone") {
            Text("Choose “iPhone Microphone” under **Microphone** if the iPhone is closer to you than your Mac or external mic. Otherwise keep your usual mic.")
        }

        DisclosureGroup("It doesn't show up") {
            VStack(alignment: .leading, spacing: 6) {
                Bullet("Lock the iPhone, wait a few seconds, then check again. It must be locked and not in use.")
                Bullet("Make sure the iPhone isn't sharing its internet (Personal Hotspot) and isn't on a call.")
                Bullet("Check both devices use the same Apple Account, with two-factor authentication on.")
                Bullet("Connect the iPhone with a USB cable. That usually fixes it straight away.")
                Bullet("If you tapped Disconnect on the iPhone, choose it again under Camera.")
                Bullet("Still nothing? Restart the iPhone, then quit and reopen VideoFilmer.")
            }
            .padding(.top, 6)
        }
        .font(.callout)
    }

    @ViewBuilder private var iPhoneStatus: some View {
        let phones = model.cameras.filter { $0.deviceType == .continuityCamera }
        let phoneMic = model.microphones.first { $0.localizedName.localizedCaseInsensitiveContains("iPhone") }

        if let phone = phones.first {
            let inUse = model.settings.cameraID == phone.uniqueID
            StatusCard(color: .green, symbol: "checkmark.circle.fill",
                       title: inUse ? "\(phone.localizedName) is your camera" : "\(phone.localizedName) is ready",
                       detail: inUse ? "You're all set. Check the preview behind this window." : "Your iPhone was found. Use it with one click:") {
                HStack {
                    if !inUse {
                        Button("Use it as the camera") { model.settings.cameraID = phone.uniqueID }
                            .buttonStyle(.borderedProminent)
                    }
                    if let mic = phoneMic, model.settings.micID != mic.uniqueID {
                        Button("Use its microphone too") { model.settings.micID = mic.uniqueID }
                    }
                }
            }
        } else {
            StatusCard(color: .orange, symbol: "iphone.slash",
                       title: "No iPhone found yet",
                       detail: "Follow the steps below. This box turns green by itself as soon as your iPhone is found.") {
                EmptyView()
            }
        }
    }

    // MARK: - Other cameras

    @ViewBuilder private var cameraGuide: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Use a camera (Sony, Canon, Fujifilm…)").font(.title2.bold())
            Text("A real camera gives the best image and background blur. There are two ways to connect it.")
                .foregroundStyle(.secondary)
        }

        Step(number: 1, symbol: "cable.connector", title: "USB streaming (simplest)") {
            Text("Many recent cameras, such as the Sony ZV‑E10, work as a webcam over USB. In the camera's menu turn on **USB Streaming** (on Sony it's in the network/USB settings), then connect it to the Mac with a USB‑C cable.")
            Text("Some brands need their free webcam app installed on the Mac first. USB streaming is often limited to 720p (the ZV‑E10 gives 1280×720 at 25 fps). For sharper 1080p or 4K, use a capture card.")
        }
        Step(number: 2, symbol: "rectangle.connected.to.line.below", title: "HDMI capture card") {
            Text("Camera HDMI out → a capture card (for example Elgato Cam Link) → the Mac's USB. Works with almost any camera. Turn off the on-screen info on the camera's HDMI output so it doesn't appear in your video.")
        }
        Step(number: 3, symbol: "video", title: "Choose it in VideoFilmer") {
            Text("Pick the camera under **Camera** in the sidebar. A message also appears when a new camera is plugged in.")
        }
        Step(number: 4, symbol: "mic", title: "Sound from the camera's microphone") {
            Text("If a mic is plugged into the camera, its sound usually comes through the same cable. Choose the camera (or the capture card) under **Microphone** too. If it isn't listed there, the camera isn't sending sound to the Mac. Plug the mic into the Mac instead.")
        }

        let external = model.cameras.filter { $0.deviceType == .external }
        StatusCard(color: external.isEmpty ? .secondary : .green,
                   symbol: external.isEmpty ? "video.slash" : "checkmark.circle.fill",
                   title: external.isEmpty ? "No external camera connected" : "Connected: \(external.map(\.localizedName).joined(separator: ", "))",
                   detail: external.isEmpty ? "Plug one in and it appears here." : "Choose it under Camera in the sidebar.") {
            EmptyView()
        }
    }
}

// MARK: - Pieces

private struct Step<Content: View>: View {
    let number: Int
    let symbol: String
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.18)).frame(width: 34, height: 34)
                Text("\(number)").font(.headline).foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 5) {
                Label(title, systemImage: symbol).font(.headline)
                content
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct StatusCard<Actions: View>: View {
    let color: Color
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                actions
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(0.35)))
    }
}

private struct Bullet: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
