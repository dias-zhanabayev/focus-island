import AppKit
import SwiftUI

@MainActor
final class BoardWindowController {
    static let shared = BoardWindowController()

    private var window: NSWindow?
    private let state = BoardWindowState()

    func show(focus: FocusCoordinator, tab: BoardTab? = nil) {
        if let tab {
            state.tab = tab
        }
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Focus Island — доска"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: BoardRootView(focus: focus, state: state))
            window.center()
            window.setFrameAutosaveName("FocusBoardWindow")
            self.window = window
        }
        focus.boardDidAppear()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
