import AppKit
import SwiftUI

public final class SettingsWindowController: NSWindowController {
    public static let shared = SettingsWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 530),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ShoutFlow Settings"
        window.center()
        window.isReleasedWhenClosed = false
        window.titleVisibility = .visible

        super.init(window: window)

        let hostingView = NSHostingView(rootView: SettingsView())
        window.contentView = hostingView
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func showSettingsWindow() {
        // Re-embed fresh view to read latest settings
        let hostingView = NSHostingView(rootView: SettingsView())
        window?.contentView = hostingView

        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
