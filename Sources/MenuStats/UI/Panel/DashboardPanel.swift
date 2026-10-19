import AppKit
import Combine
import SwiftUI

/// Borderless floating panel that can take key focus (for pickers and toggles) without activating the app's windows.
final class DashboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Shows the dashboard under the status item, like a menu: toggles on click, closes on outside click or Esc.
final class DashboardPanelController {
    let state = DashboardState()
    private let panel: DashboardPanel
    private let hosting: NSHostingView<DashboardView>
    private var monitors: [Any] = []
    private var anchor = NSPoint.zero
    private var cancellables: Set<AnyCancellable> = []

    var isVisible: Bool { panel.isVisible }
    /// Called each time the panel opens, e.g. to apply the chosen appearance.
    var onShow: () -> Void = {}
    var window: NSWindow { panel }

    init(model: AppModel, openSettings: @escaping () -> Void) {
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 900
        panel = DashboardPanel(contentRect: NSRect(x: 0, y: 0, width: DashboardView.width, height: 400),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        hosting = NSHostingView(rootView: DashboardView(model: model, state: state, maxContentHeight: screenHeight - 190,
                                                        openSettings: {}, quit: { NSApp.terminate(nil) }))
        hosting.rootView = DashboardView(model: model, state: state, maxContentHeight: screenHeight - 190,
                                         openSettings: { [weak self] in self?.close(); openSettings() },
                                         quit: { NSApp.terminate(nil) },
                                         onLayoutChange: { [weak self] in self?.fitToContent() })

        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.acceptsMouseMovedEvents = true

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.blendingMode = .behindWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        hosting.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: background.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
        state.visible = false

        // Tell the model what's on screen, so it samples processes, volumes, GPU and all sensors only when shown.
        Publishers.CombineLatest(state.$tab, state.$visible)
            .map { tab, visible in visible ? tab : nil }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak model] tab in model?.setVisibleTab(tab) }
            .store(in: &cancellables)
    }

    /// `anchor` is the bottom-center of the clicked segment, in screen coordinates.
    func toggle(tab: DashboardTab, anchor: NSPoint) {
        if panel.isVisible && state.tab == tab {
            close(reason: "clic sulla stessa voce")
        } else {
            show(tab: tab, anchor: anchor)
        }
    }

    func show(tab: DashboardTab, anchor: NSPoint) {
        onShow()
        state.tab = tab
        state.visible = true
        self.anchor = anchor
        hosting.layoutSubtreeIfNeeded()
        fitToContent()
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
            installMonitors()
        }
    }

    func close(reason: String = "programma") {
        guard panel.isVisible else { return }
        if ProcessInfo.processInfo.environment["MENUSTATS_DEBUG"] != nil { NSLog("MENUSTATS chiusura tendina: \(reason)") }
        panel.orderOut(nil)
        state.visible = false
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    /// Follows the SwiftUI content's height (tabs differ), keeping the top edge under the menu bar.
    private func fitToContent() {
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        let screen = NSScreen.screens.first { NSMouseInRect(anchor, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        var x = anchor.x - size.width / 2
        x = min(max(x, visible.minX + 6), visible.maxX - size.width - 6)
        let y = anchor.y - 6 - size.height
        panel.setFrame(NSRect(x: x, y: max(y, visible.minY + 6), width: size.width, height: size.height), display: true)
    }

    private func installMonitors() {
        // Clicks in other apps (or the desktop) close the panel, like a menu.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            self?.close(reason: "clic fuori dalla tendina")
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] event in
            if event.keyCode == 53 { self?.close(reason: "Esc"); return nil }
            return event
        }) {
            monitors.append(local)
        }
    }
}
