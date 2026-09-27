import CodexTouchBarCore
import Darwin
import Foundation

/// Follows Claude Desktop's running Code sessions through Claude Code's own
/// session registry, so it needs no Accessibility permission. Each running
/// session keeps `~/.claude/sessions/<pid>.json` current with its sidebar title
/// and status; only the fields in `ClaudeSessionRecord` are decoded.
final class ClaudeSessionMonitor {
    var onTasks: (([TaskSnapshot]) -> Void)?

    // Like a Codex `Stop`, a finished turn stays visible briefly as completed.
    private let completedDisplay: TimeInterval = 12

    private let queue = DispatchQueue(label: "com.whitney.CodexTouchBar.claude-sessions", qos: .utility)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var timer: DispatchSourceTimer?
    private var activeTasks: [String: TaskSnapshot] = [:]
    private var completedTasks: [String: TaskSnapshot] = [:]
    private var published: [TaskSnapshot]?

    init() {
        queue.setSpecific(key: queueKey, value: 1)
    }

    static var registryDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions", isDirectory: true)
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(250))
            timer.setEventHandler { [weak self] in self?.refresh() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        let cleanup = {
            self.timer?.cancel()
            self.timer = nil
            self.activeTasks.removeAll()
            self.completedTasks.removeAll()
            self.published = nil
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            cleanup()
        } else {
            queue.sync(execute: cleanup)
        }
    }

    deinit { stop() }

    /// Registrations of live Claude Desktop sessions, whatever their status.
    static func liveRecords() -> [ClaudeSessionRecord] {
        let directory = registryDirectory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.compactMap { name -> ClaudeSessionRecord? in
            // Only `<pid>.json`. The sibling `.key` files hold credentials and
            // are never opened.
            guard name.hasSuffix(".json"), let pid = Int32(name.dropLast(5)), "\(pid).json" == name else { return nil }
            let path = directory.appendingPathComponent(name, isDirectory: false).path
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_size <= ClaudeSessionRegistry.maximumFileSize,
                  let data = FileManager.default.contents(atPath: path),
                  let record = ClaudeSessionRegistry.parse(data),
                  record.pid == pid, isLive(record) else { return nil }
            return record
        }
    }

    private func refresh() {
        let now = Date()
        let records = Self.liveRecords()
        var nextActive: [String: TaskSnapshot] = [:]
        for record in records {
            guard let phase = record.phase else { continue }
            let id = record.hostSessionID
            // Keep the first start time across busy → shell → busy changes.
            let startedAt = activeTasks[id]?.startedAt ?? min(record.statusChangedAt ?? now, now)
            nextActive[id] = TaskSnapshot(
                provider: .claude,
                sessionID: id,
                title: record.title ?? "Claude Code",
                workspaceName: "Claude Code",
                category: .code,
                route: TaskRoute(provider: .claude, identifier: id, category: .code),
                phase: phase,
                toolName: nil,
                startedAt: startedAt,
                updatedAt: record.statusChangedAt ?? startedAt
            )
            completedTasks.removeValue(forKey: id)
        }

        let liveIDs = Set(records.map(\.hostSessionID))
        for (id, task) in activeTasks where nextActive[id] == nil && liveIDs.contains(id) {
            // Still open but no longer working: the turn finished. A session
            // whose process exited was closed, so it simply disappears.
            var finished = task
            finished.phase = .completed
            finished.updatedAt = now
            completedTasks[id] = finished
        }
        activeTasks = nextActive
        completedTasks = completedTasks.filter { id, task in
            liveIDs.contains(id) && now.timeIntervalSince(task.updatedAt) < completedDisplay
        }

        let tasks = Self.ordered(Array(activeTasks.values)) + Self.ordered(Array(completedTasks.values))
        guard tasks != published else { return }
        published = tasks
        DispatchQueue.main.async { [weak self] in self?.onTasks?(tasks) }
    }

    // Oldest first, so a running task's block keeps its place on the bar.
    private static func ordered(_ tasks: [TaskSnapshot]) -> [TaskSnapshot] {
        tasks.sorted { ($0.startedAt, $0.sessionID) < ($1.startedAt, $1.sessionID) }
    }

    private static func isLive(_ record: ClaudeSessionRecord) -> Bool {
        guard kill(record.pid, 0) == 0 || errno == EPERM else { return false }
        // A crashed session can leave its file behind. If macOS later reuses
        // the pid, the process start time no longer matches the registration.
        guard let recorded = record.processStartedAt, let actual = processStartTime(record.pid) else { return true }
        return abs(actual.timeIntervalSince(recorded)) < 2
    }

    private static func processStartTime(_ pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
    }
}
