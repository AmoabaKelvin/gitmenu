import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var model: AppModel!
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private var settingsWindow: NSWindow?
    private let hotKey = HotKey()
    private var isOpen = false
    private let size = NSSize(width: 400, height: 560)

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()
        model.onMenuBarChange = { [weak self] in self?.updateIcon() }
        model.onPrefsChange = { [weak self] in
            guard let self else { return }
            self.hotKey.register(self.model.prefs.hotKey)
            self.updateIcon()
        }
        model.onOpenSettings = { [weak self] in self?.showSettings() }
        hotKey.onPress = { [weak self] in self?.togglePanel() }
        hotKey.register(model.prefs.hotKey)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateIcon()

        panel = KeyPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                        backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.black.withAlphaComponent(0.15).cgColor
        let host = NSHostingView(rootView: RootView().environmentObject(model))
        host.frame = effect.bounds
        host.autoresizingMask = [.width, .height]
        effect.addSubview(host)
        panel.contentView = effect

        if let dir = Snapshot.dir { Task { await Snapshot.run(model: model, dir: dir) } }
    }

    private lazy var markImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "svg"), let img = NSImage(contentsOf: url) else { return nil }
        img.size = NSSize(width: 16, height: 16)
        img.isTemplate = true
        return img
    }()

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let total = model.unreadCount, urgent = model.urgentUnreadCount
        button.image = markImage ?? NSImage(systemSymbolName: "bell", accessibilityDescription: "GitMenu")
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        button.title = total > 0 && model.prefs.showCount ? " \(total)" : ""
        // A dimmed icon means the count cannot be trusted right now.
        button.appearsDisabled = model.issue != nil
        button.toolTip = model.issue?.title ?? (total > 0 ? "\(total) unread, \(urgent) for you" : "No unread notifications")
    }

    @objc private func toggle() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            togglePanel()
        }
    }

    private func togglePanel() {
        if isOpen { close() } else { open() }
    }

    private func showMenu() {
        if isOpen { close() }
        let menu = NSMenu()
        menu.addItem(withTitle: "Open GitMenu", action: #selector(openFromMenu), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Refresh", action: #selector(refreshFromMenu), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        let login = menu.addItem(withTitle: "Launch at login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = model.launchAtLogin ? .on : .off
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        if let v = model.updater.availableVersion {
            menu.addItem(withTitle: "Install update \(v) and relaunch", action: #selector(installUpdate), keyEquivalent: "").target = self
        } else {
            menu.addItem(withTitle: "Check for updates", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit GitMenu", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        // Attaching the menu only for this click keeps left click bound to the panel.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openFromMenu() { open() }
    @objc private func refreshFromMenu() { model.refresh() }
    @objc private func toggleLaunchAtLogin() { model.launchAtLogin.toggle() }
    @objc private func installUpdate() { Task { await model.updater.install() } }
    /// The answer shows in Settings, so open it.
    @objc private func checkForUpdates() {
        showSettings()
        Task { await model.updater.check() }
    }

    private func open() {
        guard let button = statusItem.button, let window = button.window else { return }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        var origin = NSPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 6)
        if let screen = window.screen ?? NSScreen.main {
            let f = screen.visibleFrame
            origin.x = min(max(origin.x, f.minX + 8), f.maxX - size.width - 8)
        }
        panel.setFrameOrigin(origin)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
        isOpen = true
        button.highlight(true)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window === self.panel else { return e }
            return self.handleKey(e) ? nil : e
        }
        model.popoverOpened()
    }

    private func close() {
        guard isOpen else { return }
        isOpen = false
        statusItem.button?.highlight(false)
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, !self.isOpen else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    /// The app has no main menu, so the panel's shortcuts are routed here.
    private func handleKey(_ e: NSEvent) -> Bool {
        let typing = panel.firstResponder is NSTextView
        if model.handleKey(e, typing: typing) { return true }
        let command = e.modifierFlags.intersection([.command, .control, .option]) == .command
        let key = e.charactersIgnoringModifiers ?? ""
        if typing && command, let edit = Self.editActions[key] {
            return NSApp.sendAction(edit, to: nil, from: nil)
        }
        switch (command, key) {
        case (true, "q"): NSApp.terminate(nil)
        case (true, ","): showSettings()
        case (false, _) where e.keyCode == 53: close()
        default: return false
        }
        return true
    }

    private static let editActions: [String: Selector] = [
        "v": #selector(NSText.paste(_:)), "c": #selector(NSText.copy(_:)), "x": #selector(NSText.cut(_:)), "a": #selector(NSText.selectAll(_:)),
    ]

    @objc private func showSettings() {
        close()
        if settingsWindow == nil {
            let view = SettingsView(updater: model.updater).environmentObject(model).environmentObject(model.prefs)
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = "GitMenu Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}

/// Borderless panels refuse key status by default, which would leave the search field and shortcuts dead.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
