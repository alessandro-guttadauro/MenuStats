import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var settingsWindow: SettingsWindowController!
    private var panel: DashboardPanelController!
    private var statusBar: StatusBarController!
    private var updateItem: UpdateStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        settingsWindow = SettingsWindowController(model: model)
        panel = DashboardPanelController(model: model) { [weak self] in self?.settingsWindow.show() }
        statusBar = StatusBarController(model: model, panel: panel) { [weak self] in self?.settingsWindow.show() }
        updateItem = UpdateStatusItem(updater: model.updater) { [weak self] in self?.settingsWindow.show() }
        model.start()
        model.updater.start()

        if let flag = CommandLine.arguments.firstIndex(of: "--self-test"), flag + 1 < CommandLine.arguments.count {
            SelfTest.run(statusBar: statusBar, panel: panel, output: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
        }
    }

    // Opening the app again (Finder, Spotlight) shows the settings, since there is no Dock icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow.show()
        return false
    }
}
