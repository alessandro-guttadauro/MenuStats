import AppKit
import Combine
import CryptoKit
import Foundation

/// In-app updates from the GitHub releases: checks the latest release every few hours, shows a menu bar icon
/// when a newer version exists, and installs it in place with one click.
///
/// Downloads made by the app itself carry no quarantine flag, so macOS doesn't ask "Apri comunque" again.
/// The archive is checked against the SHA-256 digest GitHub publishes for the asset, and the app inside must be
/// a MenuStats bundle with a valid signature and a higher version before anything is replaced.
final class Updater: ObservableObject {
    struct Release: Equatable {
        var version: String
        var tag: String
        var notes: String
        var page: URL
        var asset: URL
        var digest: String?
        var size: Int
        var published: Date?
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available
        case downloading(Double)
        case installing
        case failed(String)
    }

    static let repository = "thomas-addamo/MenuStats"
    static let checkInterval: TimeInterval = 6 * 3600

    @Published private(set) var state: State = .idle
    @Published private(set) var latest: Release?
    @Published private(set) var lastCheck: Date?
    @Published var automaticChecks: Bool {
        didSet { UserDefaults.standard.set(automaticChecks, forKey: "updates.automatic"); schedule() }
    }

    /// True while a newer release is waiting: drives the menu bar icon.
    var updateAvailable: Bool {
        guard let latest else { return false }
        return Self.isNewer(latest.version, than: Self.currentVersion)
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Only a packaged app can replace itself (not `swift run`).
    static var canInstall: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    private var timer: Timer?
    private var download: URLSessionDownloadTask?
    private var progressObservation: NSKeyValueObservation?

    init() {
        automaticChecks = UserDefaults.standard.object(forKey: "updates.automatic") as? Bool ?? true
    }

    func start() {
        schedule()
        guard automaticChecks else { return }
        // A little after launch, so it doesn't compete with the first samples.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.check() }
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard automaticChecks else { return }
        let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in self?.check() }
        timer.tolerance = 600
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: - Check

    func check(userInitiated: Bool = false) {
        switch state {
        case .checking, .downloading, .installing: return
        default: break
        }
        state = .checking
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MenuStats/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let release = data.flatMap(Self.parse)
            DispatchQueue.main.async {
                guard let self else { return }
                self.lastCheck = Date()
                if let release {
                    self.latest = release
                    self.state = self.updateAvailable ? .available : .upToDate
                } else {
                    let status = (response as? HTTPURLResponse)?.statusCode
                    self.state = userInitiated || self.latest == nil
                        ? .failed(error?.localizedDescription ?? "Risposta non valida da GitHub\(status.map { " (\($0))" } ?? "").")
                        : (self.updateAvailable ? .available : .upToDate)
                }
            }
        }.resume()
    }

    static func parse(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              json["draft"] as? Bool != true, json["prerelease"] as? Bool != true,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
              let assets = json["assets"] as? [[String: Any]],
              let asset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
              let url = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let published = (json["published_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return Release(version: version, tag: tag, notes: json["body"] as? String ?? "", page: page, asset: url,
                       digest: asset["digest"] as? String, size: asset["size"] as? Int ?? 0, published: published)
    }

    /// Numeric comparison of dotted versions ("1.10.0" > "1.9.3").
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Download and install

    /// `--install-update`: checks and installs without any click (used to test the whole update path).
    func installWhenAvailable() {
        check(userInitiated: true)
        var observer: AnyCancellable?
        observer = $state.sink { [weak self] state in
            switch state {
            case .available: DispatchQueue.main.async { self?.installUpdate() }
            case .upToDate, .failed: NSLog("MenuStats: aggiornamento non installato (\(state))"); observer?.cancel()
            default: break
            }
        }
        self.observer = observer
    }

    private var observer: AnyCancellable?

    func installUpdate() {
        guard let release = latest, updateAvailable, Self.canInstall else { return }
        switch state {
        case .downloading, .installing: return
        default: break
        }
        state = .downloading(0)
        let task = URLSession.shared.downloadTask(with: release.asset) { [weak self] location, _, error in
            // The temporary file is deleted when this handler returns: move it first.
            var archive: URL?
            if let location {
                let destination = FileManager.default.temporaryDirectory.appendingPathComponent("MenuStats-update-\(UUID().uuidString).zip")
                if (try? FileManager.default.moveItem(at: location, to: destination)) != nil { archive = destination }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.progressObservation = nil
                guard let archive else {
                    self.state = .failed(error?.localizedDescription ?? "Download non riuscito.")
                    return
                }
                self.state = .installing
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = Self.prepare(archive: archive, release: release)
                    DispatchQueue.main.async {
                        switch result {
                        case .success(let app): self.relaunch(into: app)
                        case .failure(let failure): self.state = .failed(failure.message)
                        }
                    }
                }
            }
        }
        progressObservation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            DispatchQueue.main.async {
                if case .downloading = self?.state { self?.state = .downloading(progress.fractionCompleted) }
            }
        }
        download = task
        task.resume()
    }

    func cancel() {
        download?.cancel()
        download = nil
        state = updateAvailable ? .available : .idle
    }

    struct Failure: Error { var message: String }

    /// Verifies the archive and unpacks the new app next to it. Runs off the main thread.
    static func prepare(archive: URL, release: Release) -> Result<URL, Failure> {
        defer { try? FileManager.default.removeItem(at: archive) }
        if let digest = release.digest, digest.hasPrefix("sha256:") {
            guard let data = try? Data(contentsOf: archive, options: .mappedIfSafe) else { return .failure(Failure(message: "Archivio illeggibile.")) }
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard "sha256:" + hash == digest else { return .failure(Failure(message: "L'archivio scaricato non corrisponde a quello pubblicato: aggiornamento annullato.")) }
        }

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MenuStats-update-\(release.version)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard run("/usr/bin/ditto", ["-x", "-k", archive.path, folder.path]) == 0 else {
            return .failure(Failure(message: "Impossibile estrarre l'archivio."))
        }
        guard let app = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
            .first(where: { $0.pathExtension == "app" }), let bundle = Bundle(url: app) else {
            return .failure(Failure(message: "L'archivio non contiene MenuStats.app."))
        }
        guard bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
            return .failure(Failure(message: "L'app scaricata non è MenuStats."))
        }
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        guard isNewer(version, than: currentVersion) else {
            return .failure(Failure(message: "La versione scaricata (\(version)) non è più recente di quella installata."))
        }
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) == 0 else {
            return .failure(Failure(message: "La firma dell'app scaricata non è valida."))
        }
        // Belt and braces: nothing here should carry the quarantine flag, but if it did macOS would ask again.
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        return .success(app)
    }

    /// Hands over to a small script that waits for MenuStats to quit, copies the new bundle over the installed
    /// one in place (keeping the login item and the fan helper's registration valid), and opens it again.
    private func relaunch(into app: URL) {
        let destination = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: destination.deletingLastPathComponent().path) else {
            state = .failed("Non ho i permessi per scrivere in \(destination.deletingLastPathComponent().path).")
            return
        }
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        NEW="$2"; DEST="$3"
        HELPER_CHANGED=1
        cmp -s "$NEW/Contents/MacOS/MenuStatsHelper" "$DEST/Contents/MacOS/MenuStatsHelper" && HELPER_CHANGED=0
        HELPER_WAS_INSTALLED=0
        [ $HELPER_CHANGED = 1 ] && launchctl print system/local.menustats.helper >/dev/null 2>&1 && HELPER_WAS_INSTALLED=1
        /usr/bin/rsync -a --delete "$NEW/" "$DEST/" || exit 1
        LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
        "$LSREGISTER" -f "$DEST"
        /usr/bin/open "$DEST"
        if [ $HELPER_WAS_INSTALLED = 1 ]; then
            sleep 3
            "$DEST/Contents/MacOS/MenuStats" --uninstall-helper >/dev/null 2>&1
            sleep 4
            "$LSREGISTER" -f "$DEST"
            "$DEST/Contents/MacOS/MenuStats" --install-helper >/dev/null 2>&1
        fi
        rm -rf "$(dirname "$NEW")"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "menustats-update", "\(getpid())", app.path, destination.path]
        do {
            try process.run()
        } catch {
            state = .failed("Impossibile avviare l'installazione: \(error.localizedDescription)")
            return
        }
        NSApp.terminate(nil)
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
