import AppKit
import SwiftUI

// MARK: - App delegate

/// Menu-bar-only app: an accessory (no Dock icon, no app switcher entry) whose
/// entire UI is the status item and the popover it opens.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        MainActor.assumeIsolated {
            let environment = AppEnvironment.shared
            environment.bootstrap()
            statusItem = StatusItemController(environment: environment)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppEnvironment.shared.shutdown()
        }
    }
}

// MARK: - Entry point

/// The status item, its popover and the utility windows are all driven from
/// AppKit, so there is deliberately no `MenuBarExtra`: it cannot distinguish a
/// right click from a left click, and the tool actions must live in the
/// right-click menu rather than being duplicated inside the panel. There is also
/// no main window. `Settings` is the cheapest scene that keeps the `App` alive
/// without presenting anything at launch.
@main
struct MeterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
