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

    private var titleTask: Task<Void, Never>?

    init(environment: AppEnvironment) {
        self.environment = environment
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureButton()
        configurePopover()
        configureMenu()
        observeTitle()
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
            accessibilityDescription: "用量统计"
        )
        button.image?.isTemplate = true
        button.toolTip = "用量统计"
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

        menu.addItem(menuItem("显示用量面板", #selector(showPanel), key: ""))
        menu.addItem(menuItem("同步数据", #selector(syncNow), key: "r"))
        menu.addItem(.separator())

        let themeItem = NSMenuItem(title: "主题", action: nil, keyEquivalent: "")
        let themeMenu = NSMenu()
        for mode in AppPreferences.ThemeMode.allCases {
            let item = menuItem(mode.label, #selector(setTheme(_:)), key: "")
            item.representedObject = mode.rawValue
            themeMenu.addItem(item)
        }
        themeItem.submenu = themeMenu
        menu.addItem(themeItem)

        menu.addItem(.separator())
        menu.addItem(menuItem("设置…", #selector(openSettings), key: ","))
        menu.addItem(menuItem("关于用量统计", #selector(openAbout), key: ""))
        menu.addItem(.separator())
        menu.addItem(menuItem("退出", #selector(quit), key: "q"))
    }

    private func menuItem(_ title: String, _ action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
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

    /// Reflects the current theme and sync state in the menu before it opens.
    private func menuNeedsUpdate() {
        menu.item(withTitle: "显示用量面板")?.isHidden = popover.isShown
        menu.item(withTitle: "同步数据")?.isEnabled = !environment.store.isSyncing

        if let themeItem = menu.item(withTitle: "主题"), let submenu = themeItem.submenu {
            for item in submenu.items {
                let mode = (item.representedObject as? String)
                    .flatMap(AppPreferences.ThemeMode.init(rawValue:))
                item.state = mode == environment.prefs.themeMode ? .on : .off
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
                title: "设置",
                root: root,
                size: NSSize(width: 660, height: 480)
            )
        }
        present(settingsWindow)
    }

    func showAbout(environment: AppEnvironment) {
        if aboutWindow == nil {
            let root = AboutView()
                .environment(environment)
                .preferredColorScheme(environment.prefs.themeMode.colorScheme)
            aboutWindow = makeWindow(
                title: "关于",
                root: root,
                size: NSSize(width: 460, height: 520)
            )
        }
        present(aboutWindow)
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

    private func present(_ window: NSWindow?) {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
