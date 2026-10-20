import Foundation

/// Names shared by the app and its privileged helper.
public enum HelperConstants {
    /// The name used up to v1.x and when running outside a built bundle (`swift run`).
    public static let legacyLabel = "local.menustats.helper"
    /// Info.plist key where build-app.sh writes the helper's launchd label.
    public static let labelKey = "MSHelperLabel"

    /// launchd label and Mach service name of the helper shipped in the app at `bundleURL`.
    /// build-app.sh derives it from the helper's contents: macOS ties an ad hoc signed daemon to the code hash it had
    /// when first registered and never refreshes that, so a changed helper must come under a new name to start at all.
    public static func label(bundleURL: URL) -> String {
        let info = NSDictionary(contentsOf: bundleURL.appendingPathComponent("Contents/Info.plist"))
        return info?[labelKey] as? String ?? legacyLabel
    }

    public static func plistName(label: String) -> String { label + ".plist" }
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
