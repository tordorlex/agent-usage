import AppKit
import Observation
import SwiftUI

/// Owns the menu-bar item, the dashboard popover, the right-click menu and the
/// two utility windows.
///
/// `MenuBarExtra` cannot distinguish a left click from a right click, and the
/// tool actions belong in a context menu rather than inside the panel, so the
/// status item is built with AppKit directly.
@MainActor
final class StatusItemController: NSObject {
    private let environment: AppEnvironment
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let menu = NSMenu()
    private let windows = UtilityWindows()

    /// The context menu is built with AppKit, so its titles have to be assigned
    /// explicitly — and because they are localized, `menu.item(withTitle:)`
    /// lookups would break the moment the language changes. Keep references and
    /// rewrite every title in `menuNeedsUpdate()` instead.
    private let showPanelItem = NSMenuItem()
    private let syncItem = NSMenuItem()
    private let themeItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let themeMenu = NSMenu()
    private var themeItems: [(mode: AppPreferences.ThemeMode, item: NSMenuItem)] = []
    private let settingsItem = NSMenuItem()
    private let aboutItem = NSMenuItem()
    private let quitItem = NSMenuItem()

    private var titleTask: Task<Void, Never>?

    init(environment: AppEnvironment) {
        self.environment = environment
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureButton()
        configurePopover()
        configureMenu()
        observeTitle()
        observeLanguage()
        // Keep the menu check marks honest if the mode changes elsewhere.
        menuNeedsUpdate()
    }

    deinit {
        titleTask?.cancel()
    }

    // MARK: - Button

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(buttonPressed(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageLeading
        button.image = NSImage(
            systemSymbolName: "chart.bar.fill",
            accessibilityDescription: "Meter"
        )
        button.image?.isTemplate = true
        button.toolTip = "Meter"
        applyTitle()
    }

    @objc private func buttonPressed(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if isSecondary {
            showMenu()
        } else {
            togglePopover()
        }
    }

    // MARK: - Popover

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: PanelMetrics.width, height: PanelMetrics.height)
        popover.contentViewController = NSHostingController(
            rootView: DashboardPanel()
                .environment(environment)
                .environment(environment.store)
                .environment(environment.prefs)
                .environment(environment.engine)
                .preferredColorScheme(environment.prefs.themeMode.colorScheme)
        )
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        // The hosting controller is reused, so `.task` will not run again:
        // refresh explicitly to keep the panel current on every open.
        Task { await environment.store.reload() }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Right-click menu

    private func configureMenu() {
        menu.delegate = self
        menu.autoenablesItems = false

        install(showPanelItem, action: #selector(showPanel), key: "")
        install(syncItem, action: #selector(syncNow), key: "r")
        menu.addItem(.separator())

        for mode in AppPreferences.ThemeMode.allCases {
            let item = menuItem(action: #selector(setTheme(_:)), key: "")
            item.representedObject = mode.rawValue
            themeMenu.addItem(item)
            themeItems.append((mode, item))
        }
        themeItem.submenu = themeMenu
        menu.addItem(themeItem)

        menu.addItem(.separator())
        install(settingsItem, action: #selector(openSettings), key: ",")
        install(aboutItem, action: #selector(openAbout), key: "")
        menu.addItem(.separator())
        install(quitItem, action: #selector(quit), key: "q")
    }

    /// Adds an item to the menu and points it at this controller. Titles are
    /// assigned later by `menuNeedsUpdate()`.
    private func install(_ item: NSMenuItem, action: Selector, key: String) {
        item.target = self
        item.action = action
        item.keyEquivalent = key
        menu.addItem(item)
    }

    private func menuItem(action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func showMenu() {
        if popover.isShown { popover.performClose(nil) }
        menuNeedsUpdate()
        // Assigning the menu makes the next click open it in the right place,
        // then it is detached so left clicks keep toggling the popover.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    /// Rewrites every title (the language may have changed), then reflects the
    /// current theme and sync state. Runs before the menu opens and whenever the
    /// language changes.
    private func menuNeedsUpdate() {
        showPanelItem.title = Copy.panelShow
        syncItem.title = Copy.syncNow
        themeItem.title = Copy.theme
        settingsItem.title = Copy.settingsEllipsis
        aboutItem.title = Copy.aboutMeter
        quitItem.title = Copy.quit
        for entry in themeItems { entry.item.title = entry.mode.label }

        showPanelItem.isHidden = popover.isShown
        syncItem.isEnabled = !environment.store.isSyncing
        for entry in themeItems {
            entry.item.state = entry.mode == environment.prefs.themeMode ? .on : .off
        }
    }

    /// Menu and window titles are AppKit strings, so unlike the SwiftUI panel
    /// they do not re-render on their own: re-arm an observation on the active
    /// language to rewrite them in place.
    private func observeLanguage() {
        withObservationTracking {
            _ = Localization.shared.language
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.menuNeedsUpdate()
                self.windows.refreshTitles()
                self.observeLanguage()
            }
        }
    }

    // MARK: - Actions

    @objc private func showPanel() {
        showPopover()
    }

    @objc private func syncNow() {
        Task { await environment.store.triggerSync() }
    }

    @objc private func setTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = AppPreferences.ThemeMode(rawValue: raw) else { return }
        environment.prefs.themeMode = mode
        menuNeedsUpdate()
    }

    @objc private func openSettings() {
        windows.showSettings(environment: environment)
    }

    @objc private func openAbout() {
        windows.showAbout(environment: environment)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Title

    /// Re-arms itself after each change so the menu-bar text tracks the data.
    private func observeTitle() {
        withObservationTracking {
            applyTitle()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observeTitle()
            }
        }
    }

    private func applyTitle() {
        guard let button = statusItem.button else { return }
        let title = environment.prefs.trayTitle(
            tokens: environment.store.todayTokens,
            costUsd: environment.store.todayCostUsd
        )
        guard let title else {
            button.attributedTitle = NSAttributedString(string: "")
            return
        }
        // Monospaced digits stop the item jittering as the numbers tick.
        button.attributedTitle = NSAttributedString(
            string: " " + title,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            ]
        )
    }
}

extension StatusItemController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        menuNeedsUpdate()
    }
}

// MARK: - Utility windows

/// Settings and About used to be SwiftUI `Window` scenes opened with
/// `openWindow`; with the panel hosted in an `NSPopover` there is no scene
/// context, so they are plain AppKit windows hosting the same SwiftUI views.
@MainActor
final class UtilityWindows {
    private var settingsWindow: NSWindow?
    private var aboutWindow: NSWindow?

    func showSettings(environment: AppEnvironment) {
        if settingsWindow == nil {
            let root = SettingsView()
                .environment(environment)
                .environment(environment.store)
                .environment(environment.prefs)
                .environment(environment.engine)
                .preferredColorScheme(environment.prefs.themeMode.colorScheme)
            settingsWindow = makeWindow(
                title: Copy.settings,
                root: root,
                size: NSSize(width: 660, height: 480)
            )
        }
        present(settingsWindow, title: Copy.settings)
    }

    func showAbout(environment: AppEnvironment) {
        if aboutWindow == nil {
            let root = AboutView()
                .environment(environment)
                .preferredColorScheme(environment.prefs.themeMode.colorScheme)
            aboutWindow = makeWindow(
                title: Copy.aboutMeter,
                root: root,
                size: NSSize(width: 460, height: 520)
            )
        }
        present(aboutWindow, title: Copy.aboutMeter)
    }

    /// The hosted SwiftUI content follows the language on its own; the AppKit
    /// window titles do not, so they are rewritten from `StatusItemController`.
    func refreshTitles() {
        settingsWindow?.title = Copy.settings
        aboutWindow?.title = Copy.aboutMeter
    }

    private func makeWindow(title: String, root: some View, size: NSSize) -> NSWindow {
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = [.titled, .closable]
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    private func present(_ window: NSWindow?, title: String) {
        guard let window else { return }
        window.title = title
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
