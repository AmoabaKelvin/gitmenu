import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var model: AppModel!
    private var clickMonitor: Any?
    private let size = NSSize(width: 400, height: 560)

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()
        model.onUnreadChange = { [weak self] total, urgent in self?.updateIcon(total: total, urgent: urgent) }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateIcon(total: model.unreadCount, urgent: model.urgentUnreadCount)

        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
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

    private func updateIcon(total: Int, urgent: Int) {
        guard let button = statusItem.button else { return }
        button.image = markImage ?? NSImage(systemSymbolName: "bell", accessibilityDescription: "GitMenu")
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        button.title = total > 0 ? " \(total)" : ""
        button.toolTip = total > 0 ? "\(total) unread, \(urgent) for you" : "No unread notifications"
    }

    @objc private func toggle() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else if panel.isVisible {
            close()
        } else {
            open()
        }
    }

    private func showMenu() {
        if panel.isVisible { close() }
        let menu = NSMenu()
        menu.addItem(withTitle: "Open GitMenu", action: #selector(openFromMenu), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Refresh", action: #selector(refreshFromMenu), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        let login = menu.addItem(withTitle: "Launch at login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = model.launchAtLogin ? .on : .off
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

    private func open() {
        guard let button = statusItem.button, let window = button.window else { return }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        var origin = NSPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 6)
        if let screen = window.screen ?? NSScreen.main {
            let f = screen.visibleFrame
            origin.x = min(max(origin.x, f.minX + 8), f.maxX - size.width - 8)
        }
        panel.setFrameOrigin(origin)
        panel.makeKeyAndOrderFront(nil)
        button.highlight(true)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
        model.popoverOpened()
    }

    private func close() {
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
    }

    func windowDidResignKey(_ notification: Notification) {
        if panel.isVisible { close() }
    }
}
