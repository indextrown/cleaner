import AppKit
import SwiftUI

@main
struct CleanerApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Cleaner") {
            RootView()
                .frame(minWidth: 960, minHeight: 600)
        }
        .windowToolbarStyle(.unified)
    }
}

/// `swift run CleanerApp`처럼 번들 없이 실행해도 Dock에 나타나고 창이 앞으로 오게 한다.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        DevSnapshot.scheduleIfRequested()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
