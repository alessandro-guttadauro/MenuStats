import AppKit

/// Actions that change system state. Each one goes through macOS's own authorization prompt.
enum SystemActions {
    /// Low Power Mode via `pmset`, which needs an administrator password (asked by macOS, not by MenuStats).
    static func setLowPowerMode(_ enabled: Bool, completion: @escaping () -> Void) {
        let script = "do shell script \"/usr/bin/pmset -a lowpowermode \(enabled ? 1 : 0)\" with administrator privileges"
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            if let error { NSLog("MenuStats: pmset failed: \(error)") }
            DispatchQueue.main.async(execute: completion)
        }
    }

    /// Locks the screen at once, like Control-Command-Q, without Accessibility permission. Uses the login framework's
    /// `SACLockScreenImmediate`; if a future macOS removes it, falls back to putting the display to sleep (which
    /// locks when "Require password" is set to immediately in System Settings).
    static func lockScreen() {
        typealias LockFunction = @convention(c) () -> Int32
        if let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
           let symbol = dlsym(handle, "SACLockScreenImmediate") {
            _ = unsafeBitCast(symbol, to: LockFunction.self)()
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        try? process.run()
    }

    /// Whether the screen is unlocked, on and in front: the only time an automatic lock makes sense.
    static func screenIsUsable() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        let locked = (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
        let onConsole = (session["kCGSSessionOnConsoleKey"] as? Bool) ?? true
        return !locked && onConsole && CGDisplayIsAsleep(CGMainDisplayID()) == 0
    }

    static func openLocationSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")
    }

    static func openBatterySettings() {
        open("x-apple.systempreferences:com.apple.Battery-Settings.extension")
    }

    static func openActivityMonitor() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
                                           configuration: .init())
    }

    private static func open(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }
}
