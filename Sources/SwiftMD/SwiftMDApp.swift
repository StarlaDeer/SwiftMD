import AppKit
import SwiftUI

@main
struct SwiftMDApp: App {
    init() {
        // Launched via `swift run` there is no app bundle, so ask to be a regular foreground app.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
        // The MiniDisc icon (drawn by Tools/icon). SwiftMD.app gets it from its Info.plist; when run
        // with `swift run` there's no app bundle, so set it here.
        if Bundle.main.bundleURL.pathExtension != "app",
           let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"), let icon = NSImage(contentsOf: url) {
            NSApplication.shared.applicationIconImage = icon
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
