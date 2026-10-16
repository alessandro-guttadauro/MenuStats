import Foundation
import ServiceManagement

/// "Open at login" through SMAppService. Only works when running from the MenuStats.app bundle,
/// not from `swift run`, because macOS registers the app by its bundle.
enum LoginItem {
    static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("MenuStats: login item change failed: \(error.localizedDescription)")
        }
        // The user may need to allow it in System Settings ▸ General ▸ Login Items.
        if status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
