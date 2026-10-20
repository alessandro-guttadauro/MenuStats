import Darwin
import Foundation

/// Recognizes AI coding tools at work with no setup, from two signals that need no permissions:
///   - their session transcripts on disk (Claude Code, Codex, Gemini CLI, OpenCode) are written at every step;
///     only modification dates are read, never the contents;
///   - their processes (`claude`, `codex`, …) and the commands they run (builds, tests) use the CPU.
/// The hook files in ~/.menustats/ai still count, for tools that report themselves.
final class AIActivityMonitor {
    struct Reading: Equatable {
        /// Names of the tools at work, one entry per active session ("Claude Code", "Codex"…).
        var sessions: [String] = []
        var isWorking: Bool { !sessions.isEmpty }
    }

    /// A transcript written this recently means its tool is working.
    static let transcriptWindow: TimeInterval = 45
    /// Share of one core above which a tool's process tree counts as busy.
    static let busyCPU = 0.03

    struct TranscriptSource {
        var tool: String
        var root: URL
        /// How deep below `root` the transcript files sit.
        var depth: Int
        var extensions: Set<String>
    }

    static let transcriptSources: [TranscriptSource] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            TranscriptSource(tool: "Claude Code", root: home.appendingPathComponent(".claude/projects"), depth: 2, extensions: ["jsonl"]),
            TranscriptSource(tool: "Codex", root: home.appendingPathComponent(".codex/sessions"), depth: 4, extensions: ["jsonl"]),
            TranscriptSource(tool: "Gemini CLI", root: home.appendingPathComponent(".gemini/tmp"), depth: 3, extensions: ["json", "jsonl"]),
            TranscriptSource(tool: "OpenCode", root: home.appendingPathComponent(".local/share/opencode/storage/message"), depth: 2, extensions: ["json"]),
        ]
    }()

    /// Executable names of AI agents and the tool each belongs to.
    static let agentProcesses: [String: String] = [
        "claude": "Claude Code", "codex": "Codex", "gemini": "Gemini CLI", "opencode": "OpenCode", "aider": "Aider",
        "cursor-agent": "Cursor", "copilot": "Copilot", "goose": "Goose", "amp": "Amp", "qwen": "Qwen Code",
    ]

    private let sources: [TranscriptSource]
    private let hookDirectory: URL?
    private var candidates: [(tool: String, url: URL)] = []
    private var candidatesTime = -Double.infinity
    private var agents: [(pid: pid_t, tool: String)] = []
    private var agentsTime = -Double.infinity
    private var lastCPU: [pid_t: UInt64] = [:]
    /// Share of one core used by each agent's process tree in the last sample.
    private var lastShare: [pid_t: Double] = [:]
    private var lastSampleTime: Double?
    /// Busy readings in a row per agent: a CPU spike alone (an agent starting up) doesn't count.
    private var busyStreak: [pid_t: Int] = [:]
    private let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }()

    init(sources: [TranscriptSource] = AIActivityMonitor.transcriptSources, hookDirectory: URL? = AwakeController.aiDirectory) {
        self.sources = sources
        self.hookDirectory = hookDirectory
    }

    func sample(hookStaleMinutes: Int, now: Date = Date()) -> Reading {
        var sessions: [String] = []
        if let hookDirectory {
            let hooks = AwakeController.aiWorkingCount(staleAfter: hookStaleMinutes, now: now, in: hookDirectory)
            sessions += Array(repeating: "IA", count: hooks)
        }
        let transcripts = activeTranscripts(now: now)
        sessions += transcripts
        // Processes add what transcripts can't see (a long build or test run with nothing written meanwhile),
        // but a busy `claude` whose transcript already counts is the same session.
        for tool in busyAgents() where !transcripts.contains(tool) && !sessions.contains(tool) {
            sessions.append(tool)
        }
        if sessions.count > 1 { sessions.removeAll { $0 == "IA" } } // hooks usually duplicate a detected session
        return Reading(sessions: sessions)
    }

    // MARK: - Transcripts

    /// One entry per transcript written in the last `transcriptWindow` seconds.
    func activeTranscripts(now: Date = Date()) -> [String] {
        let uptime = ProcessInfo.processInfo.systemUptime
        // Listing folders is the costly part: the candidates (files touched in the last day) refresh every minute,
        // and each sample only reads their modification dates.
        if uptime - candidatesTime > 60 {
            candidatesTime = uptime
            candidates = sources.flatMap { source in
                Self.files(in: source.root, depth: source.depth, extensions: source.extensions, modifiedAfter: now.addingTimeInterval(-86_400))
                    .map { (source.tool, $0) }
            }
        }
        var active: [String] = []
        for candidate in candidates {
            guard let modified = Self.modificationDate(candidate.url), now.timeIntervalSince(modified) < Self.transcriptWindow else { continue }
            active.append(candidate.tool)
        }
        // A session that started in the last minute isn't a candidate yet: look for brand-new files too.
        if active.isEmpty, uptime - candidatesTime > 5,
           sources.contains(where: { Self.directoryChanged($0.root, depth: $0.depth, since: now.addingTimeInterval(-Self.transcriptWindow)) }) {
            candidatesTime = -.infinity // rescan on the next sample
        }
        return active
    }

    static func files(in root: URL, depth: Int, extensions: Set<String>, modifiedAfter date: Date) -> [URL] {
        guard depth >= 0 else { return [] }
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let items = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var result: [URL] = []
        for item in items {
            guard let values = try? item.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true {
                // Skip old dated folders (Codex keeps one per day): a folder untouched for a month holds no live session.
                if depth > 1, let modified = values.contentModificationDate, modified < date.addingTimeInterval(-86_400 * 30) { continue }
                result += files(in: item, depth: depth - 1, extensions: extensions, modifiedAfter: date)
            } else if extensions.contains(item.pathExtension.lowercased()), (values.contentModificationDate ?? .distantPast) > date {
                result.append(item)
            }
        }
        return result
    }

    /// True when a folder down to `depth` got a new entry after `date` (a new session file).
    private static func directoryChanged(_ root: URL, depth: Int, since date: Date) -> Bool {
        guard let modified = modificationDate(root) else { return false }
        if modified > date { return true }
        guard depth > 1, let items = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                                                   options: [.skipsHiddenFiles]) else { return false }
        return items.contains { item in
            (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && (modificationDate(item) ?? .distantPast) > date
        }
    }

    private static func modificationDate(_ url: URL) -> Date? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)
    }

    // MARK: - Processes

    /// Tools whose process tree has used the CPU for two samples in a row.
    func busyAgents() -> [String] {
        let uptime = ProcessInfo.processInfo.systemUptime
        if uptime - agentsTime > 15 {
            agentsTime = uptime
            agents = Self.findAgents()
        }
        let elapsed = lastSampleTime.map { uptime - $0 } ?? 0
        lastSampleTime = uptime
        var cpu: [pid_t: UInt64] = [:]
        var busy: [String] = []
        for agent in agents {
            let tree = [agent.pid] + Self.descendants(of: agent.pid)
            var total: UInt64 = 0
            for pid in tree {
                guard let time = cpuTime(pid) else { continue }
                cpu[pid] = time
                if let previous = lastCPU[pid], time >= previous { total += time - previous }
            }
            let share = elapsed > 0 ? Double(total) / 1e9 / elapsed : 0
            lastShare[agent.pid] = share
            let streak = share > Self.busyCPU ? (busyStreak[agent.pid] ?? 0) + 1 : 0
            busyStreak[agent.pid] = streak
            if streak >= 2 { busy.append(agent.tool) }
        }
        lastCPU = cpu
        busyStreak = busyStreak.filter { pid, _ in agents.contains { $0.pid == pid } }
        return busy
    }

    private static func findAgents() -> [(pid: pid_t, tool: String)] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        return pids.prefix(Int(count)).compactMap { pid in
            guard pid > 0, proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
            let executable = String(cString: path)
            return Self.agentTool(forExecutable: executable).map { (pid, $0) }
        }
    }

    /// The tool an executable belongs to, if it is an AI agent. The name must match exactly: the Claude desktop app's
    /// own process is "Claude" (capital C) and its window helpers use the CPU all the time, so counting it kept
    /// the Mac awake for as long as the app was open. Claude Code inside the app runs as a separate lowercase
    /// "claude" executable, which is the one that counts. Other GUI app executables never count either.
    static func agentTool(forExecutable path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        guard let tool = agentProcesses[name] else { return nil }
        // An app's main executable (…/Name.app/Contents/MacOS/Name) is an interface, not an agent, unless it is one of
        // the command-line agents shipped as a minimal bundle (Claude Code's "claude.app", Codex's "CodexCLI.app").
        if let range = path.range(of: ".app/Contents/MacOS/") {
            let bundle = (String(path[..<range.lowerBound]) as NSString).lastPathComponent
            let cliBundles: Set<String> = ["claude", "CodexCLI"]
            if !cliBundles.contains(bundle) { return nil }
        }
        return tool
    }

    /// What the last sample saw, for `--ai-status`: transcripts written recently and each agent's CPU.
    func explain(now: Date = Date()) -> [String] {
        var lines = activeTranscripts(now: now).map { "conversazione aggiornata: \($0)" }
        for agent in agents {
            let share = lastShare[agent.pid] ?? 0
            let busy = (busyStreak[agent.pid] ?? 0) >= 2
            lines.append(String(format: "processo %@ (pid %d): CPU %.1f%%%@", agent.tool, agent.pid, share * 100, busy ? " → al lavoro" : ""))
        }
        if lines.isEmpty { lines = ["nessun agente IA in esecuzione"] }
        return lines
    }

    private static func descendants(of pid: pid_t, depth: Int = 0) -> [pid_t] {
        guard depth < 6 else { return [] }
        var children = [pid_t](repeating: 0, count: 256)
        let count = proc_listchildpids(pid, &children, Int32(children.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        let direct = Array(children.prefix(Int(count))).filter { $0 > 0 }
        return direct + direct.flatMap { descendants(of: $0, depth: depth + 1) }
    }

    private func cpuTime(_ pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return nil }
        return (info.ri_user_time + info.ri_system_time) * timebase.numer / timebase.denom
    }
}
