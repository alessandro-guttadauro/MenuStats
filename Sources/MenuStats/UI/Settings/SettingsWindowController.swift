import AppKit
import SwiftUI

final class SettingsWindowController {
    private var window: NSWindow?
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model, settings: model.settings)))
            window.title = "Impostazioni MenuStats"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.setContentSize(NSSize(width: 820, height: 600))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        // MenuStats is a menu bar (accessory) app, so it must be activated explicitly to come to the front.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
