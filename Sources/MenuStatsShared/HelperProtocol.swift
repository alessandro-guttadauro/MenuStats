import Foundation

/// Names shared by the app and its privileged helper.
public enum HelperConstants {
    public static let machService = "local.menustats.helper"
    public static let plistName = "local.menustats.helper.plist"
    public static let appIdentifier = "local.menustats"
    /// Bumped whenever the XPC interface changes, so the app can ask for a reinstall.
    public static let version = 2
}

/// XPC interface of MenuStatsHelper (runs as root, launched by launchd). Every reply carries an error message or nil.
@objc public protocol MenuStatsHelperProtocol {
    func version(reply: @escaping (Int) -> Void)
    /// Fixes fan `index` at `rpm`, which must lie between the fan's factory minimum (F{n}Mn) and maximum (F{n}Mx).
    func setFanSpeed(index: Int, rpm: Double, reply: @escaping (String?) -> Void)
    /// Gives fan `index` back to the system's automatic control.
    func setFanAutomatic(index: Int, reply: @escaping (String?) -> Void)
    /// All fans back to automatic.
    func resetFans(reply: @escaping (String?) -> Void)
    /// Keeps the Mac awake with the lid closed (`true`) or gives sleep back to macOS (`false`). Held only while this
    /// connection lives and renews it with `renewLidAwake` at least every `lidLeaseSeconds`.
    func setLidAwake(_ on: Bool, reply: @escaping (String?) -> Void)
    /// Renews the lease; replies whether the lid is still kept awake for this client and, if not, why it was released.
    func renewLidAwake(reply: @escaping (Bool, String?) -> Void)
}

public extension HelperConstants {
    /// Without a renewal for this long (the app hangs, a session is forgotten) the helper lets the Mac sleep again.
    static let lidLeaseSeconds: Double = 180
    /// The helper refuses or drops lid-closed awake on battery at or below this charge (0…1), whatever the app says.
    static let lidMinimumBattery = 0.10
}
