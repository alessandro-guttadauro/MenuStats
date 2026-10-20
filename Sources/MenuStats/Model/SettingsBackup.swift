import AppKit
import Foundation

/// Saves every MenuStats preference to a property list file and restores it, e.g. on a new Mac.
/// The file holds only MenuStats' own keys (no macOS window state, no menu bar geometry of this screen).
enum SettingsBackup {
    enum Failure: LocalizedError {
        case unreadable, notABackup

        var errorDescription: String? {
            switch self {
            case .unreadable: "Il file non si può leggere."
            case .notABackup: "Il file non è un backup delle impostazioni di MenuStats."
            }
        }
    }

    static let fileExtension = "plist"
    private static let marker = "MenuStatsBackupVersion"
    /// Keys owned by macOS or by this Mac's screen, which make no sense elsewhere.
    private static let excludedPrefixes = ["NS", "Apple", "com.apple.", "WebKit"]
    private static let excludedKeys: Set<String> = ["menubarFitGeometry"]

    private static var domain: String { Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName }

    static var suggestedFileName: String {
        let date = Date().formatted(.iso8601.year().month().day())
        return "MenuStats impostazioni \(date).\(fileExtension)"
    }

    private static func isOwnKey(_ key: String) -> Bool {
        !excludedKeys.contains(key) && !excludedPrefixes.contains { key.hasPrefix($0) }
    }

    /// The part of a defaults domain that goes into a backup.
    static func ownValues(_ values: [String: Any]) -> [String: Any] {
        values.filter { isOwnKey($0.key) && $0.key != marker }
    }

    static func export(to url: URL) throws {
        let defaults = UserDefaults.standard
        defaults.synchronize()
        var values = ownValues(defaults.persistentDomain(forName: domain) ?? [:])
        values[marker] = 1
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
    }

    /// Writes the file's values over the current ones. Settings are read at launch, so the app reopens afterwards.
    static func importAndRelaunch(from url: URL) throws {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw Failure.unreadable }
        guard plist[marker] != nil else { throw Failure.notABackup }
        let defaults = UserDefaults.standard
        for (key, value) in ownValues(plist) { defaults.set(value, forKey: key) }
        defaults.synchronize()
        relaunch()
    }

    private static func relaunch() {
        // Without an app bundle (`swift run`) there is nothing to reopen: the values apply at the next start.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"",
                             "menustats-import", "\(getpid())", Bundle.main.bundleURL.path]
        guard (try? process.run()) != nil else { return }
        NSApp.terminate(nil)
    }
}
