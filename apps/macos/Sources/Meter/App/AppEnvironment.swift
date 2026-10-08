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

    /// True between a manual restart and the next handshake, so the status line
    /// can say "restarting" rather than "starting".
    private(set) var isRestarting = false

    /// Shown in the panel footer and in Settings. Derived from the engine's
    /// phase instead of being stored as a sentence, so it follows a language
    /// change like every other string.
    var engineStatusText: String {
        switch engine.phase {
        case .failed(let failure): return failure.message
        case .running(let port): return Copy.engineConnected(port)
        case .idle, .starting:
            return isRestarting ? Copy.engineRestarting : Copy.engineStarting
        }
    }

    private var client: LocalAPIClient?
    private var didBootstrap = false

    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true

        engine.onReady = { [weak self] host, port in
            guard let self else { return }
            self.isRestarting = false

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

        engine.takesOwnership = prefs.takesOwnership
        engine.start()
    }

    /// Manual recovery path offered in Settings.
    func restartEngine() {
        store.detach()
        client = nil
        isRestarting = true
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

