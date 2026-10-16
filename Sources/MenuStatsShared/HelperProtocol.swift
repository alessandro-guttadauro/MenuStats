import Foundation

/// Names shared by the app and its privileged helper.
public enum HelperConstants {
    public static let machService = "local.menustats.helper"
    public static let plistName = "local.menustats.helper.plist"
    public static let appIdentifier = "local.menustats"
    /// Bumped whenever the XPC interface changes, so the app can ask for a reinstall.
    public static let version = 1
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
}
