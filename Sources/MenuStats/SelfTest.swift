import AppKit

/// `MenuStats --self-test <dir>`: drives the real app. Opens every dashboard tab from its menu bar segment
/// (same code path as a click), captures the panel window and the status item, logs geometry, then quits.
/// The app only captures its own windows, so no screen-recording permission is needed.
enum SelfTest {
    static func run(statusBar: StatusBarController, panel: DashboardPanelController, output: URL) {
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var log: [String] = []
        let modules: [(ModuleID, DashboardTab)] = DashboardTab.allCases.map { tab in
            (ModuleID.allCases.first { $0.tab == tab && Settings.shared.isEnabled($0) } ?? .cpu, tab)
        }

        func step(_ index: Int) {
            guard index < modules.count else {
                panel.close()
                for (number, button) in statusBar.buttons.enumerated() {
                    capture(button, to: output.appendingPathComponent("statusitem-\(number).png"))
                    log.append("statusitem \(number): \(button.window.map { NSStringFromRect($0.frame) } ?? "-")")
                }
                try? log.joined(separator: "\n").write(to: output.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
                return
            }
            let (module, tab) = modules[index]
            let anchor = statusBar.anchor(for: module) ?? NSPoint(x: NSScreen.main!.frame.midX, y: NSScreen.main!.visibleFrame.maxY)
            panel.show(tab: tab, anchor: anchor)
            // Give SwiftUI, Charts and the resize a moment, then capture.
            // Per-process network data needs two nettop samples, so the network tab waits longer.
            DispatchQueue.main.asyncAfter(deadline: .now() + (tab == .network ? 4 : 1.5)) {
                let window = panel.window
                let screen = window.screen?.visibleFrame ?? .zero
                let inside = screen.contains(window.frame)
                log.append("\(tab.rawValue): visibile=\(panel.isVisible) anchor=\(NSStringFromPoint(anchor)) frame=\(NSStringFromRect(window.frame)) dentroSchermo=\(inside)")
                if let view = window.contentView { capture(view, to: output.appendingPathComponent("live-\(tab.rawValue).png")) }
                step(index + 1)
            }
        }
        // Let a few samples arrive first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { step(0) }
    }

    private static func capture(_ view: NSView, to url: URL) {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}
