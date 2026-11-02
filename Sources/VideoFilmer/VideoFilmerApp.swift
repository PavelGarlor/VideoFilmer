import AppKit
import SwiftUI

@main
struct VideoFilmerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("VideoFilmer") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1000, minHeight: 680)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .help) {
                Button("Use Your iPhone as a Camera…") { model.cameraGuide = .iPhone }
                Button("Use a Camera (Sony, Canon…)…") { model.cameraGuide = .camera }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
