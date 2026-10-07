import AppKit
import Observation
import SwiftUI

/// Owns the long-lived objects and connects the sidecar to the store.
///
/// Wiring is push-based: `EngineController` reports the handshake through
/// `onReady`, at which point an API client is built against the ephemeral port.
///
/// A single shared instance is used because the menu-bar label must render
/// before any window or popover exists, and the app delegate needs the engine
/// for shutdown.
@MainActor
@Observable
final class AppEnvironment {
    static let shared = AppEnvironment()

    let engine = EngineController()
    let prefs = AppPreferences()
    let store = UsageStore()

    /// Populated once the engine reports its port; shown in Settings.
    private(set) var engineStatusText: String = "正在启动统计引擎…"

    private var client: LocalAPIClient?
    private var didBootstrap = false

    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true

        engine.onReady = { [weak self] host, port in
            guard let self else { return }
            self.engineStatusText = "已连接 127.0.0.1:\(port)"

            if let existing = self.client {
                // The sidecar binds an ephemeral port, so a restart changes it.
                Task { [weak self] in
                    await existing.updateEndpoint(host: host, port: port)
                    self?.store.attach(client: existing)
                }
            } else {
                let client = LocalAPIClient(host: host, port: port)
                self.client = client
                Task { [weak self] in
                    self?.store.attach(client: client)
                }
            }
        }

        engine.onUnavailable = { [weak self] reason in
            guard let self else { return }
            self.engineStatusText = reason
        }

        engine.takesOwnership = prefs.takesOwnership
        engine.start()
    }

    /// Manual recovery path offered in Settings.
    func restartEngine() {
        store.detach()
        client = nil
        engineStatusText = "正在重启统计引擎…"
        engine.restart()
    }

    func shutdown() {
        store.detach()
        engine.stop()
    }

    var dataDir: URL { engine.dataDir }
    var engineVersion: String { engine.engineVersion }
}

enum WindowID {
    static let settings = "settings"
    static let about = "about"
}

