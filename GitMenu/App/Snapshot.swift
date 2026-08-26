import AppKit
import SwiftUI

/// Dev aid: `GitMenu --snapshot DIR` renders the popover views to PNGs and quits.
enum Snapshot {
    static var dir: String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--snapshot"), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    @MainActor
    static func run(model: AppModel, dir: String) async {
        try? await Task.sleep(for: .seconds(4))
        await render(RootView().environmentObject(model), to: "\(dir)/inbox.png")
        model.tab = .assigned
        await render(RootView().environmentObject(model), to: "\(dir)/inbox-all.png")
        if let t = model.visible.first(where: { model.details[$0.id]?.latestActivity != nil }) {
            model.selected = t
            await render(RootView().environmentObject(model), to: "\(dir)/detail.png")
        }
        model.signOut()
        await render(RootView().environmentObject(model), to: "\(dir)/signin.png")
        NSApp.terminate(nil)
    }

    @MainActor
    private static func render<V: View>(_ view: V, to path: String) async {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 560)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = host
        win.backgroundColor = .windowBackgroundColor
        win.orderFront(nil)
        try? await Task.sleep(for: .seconds(2))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        win.orderOut(nil)
    }
}
