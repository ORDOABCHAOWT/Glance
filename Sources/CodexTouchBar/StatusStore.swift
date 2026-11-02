import CodexTouchBarCore
import Foundation

@MainActor
final class StatusStore {
    var onChange: ((DashboardSnapshot) -> Void)?

    private(set) var snapshot = DashboardSnapshot() {
        didSet { onChange?(snapshot) }
    }
    private var hookTasksByID: [String: TaskSnapshot] = [:]
    private var detectedTasksByID: [String: TaskSnapshot] = [:]
    // A `Stop` hook is authoritative. Keep a short in-memory tombstone so the
    // log-index fallback cannot immediately resurrect that completed task.
    private var suppressedDetectedTaskIDs: [String: Date] = [:]
    private var titlesByID: [String: String] = [:]
    private var cleanupTimer: Timer?

    private let detectedTaskSuppression: TimeInterval = 3 * 60

    init() {
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.removeExpiredTasks() }
        }
    }

    func accept(_ packet: HookPacket) {
        if packet.eventName == "SessionEnd" {
            hookTasksByID.removeValue(forKey: packet.sessionID)
            suppressDetectedTask(packet.sessionID, at: packet.occurredAt)
            publish()
            return
        }
        guard let phase = packet.phase else { return }

        if phase == .completed || phase == .failed {
            hookTasksByID.removeValue(forKey: packet.sessionID)
            suppressDetectedTask(packet.sessionID, at: packet.occurredAt)
            publish()
            return
        }

        // A new live event on the same thread means a new turn has started.
        suppressedDetectedTaskIDs.removeValue(forKey: packet.sessionID)

        if phase == .idle, hookTasksByID[packet.sessionID] == nil {
            return
        }

        let prior = hookTasksByID[packet.sessionID]
        let title = titlesByID[packet.sessionID]
            ?? prior?.title
            ?? detectedTasksByID[packet.sessionID]?.title
            ?? packet.workspaceName
        hookTasksByID[packet.sessionID] = TaskSnapshot(
            sessionID: packet.sessionID,
            title: title,
            workspaceName: packet.workspaceName,
            phase: phase,
            toolName: phase == .usingTool ? packet.toolName : nil,
            startedAt: prior?.startedAt ?? packet.occurredAt,
            updatedAt: packet.occurredAt
        )
        publish()
    }

    func updateDetectedTasks(_ tasks: [TaskSnapshot]) {
        let now = Date()
        detectedTasksByID = Dictionary(uniqueKeysWithValues: tasks.compactMap { task in
            isDetectedTaskSuppressed(task.sessionID, at: now) ? nil : (task.sessionID, task)
        })
        for (id, task) in detectedTasksByID where hookTasksByID[id] != nil {
            hookTasksByID[id]?.title = task.title
        }
        publish()
    }

    func updateThreadTitles(_ titles: [String: String]) {
        titlesByID.merge(titles) { _, new in new }
        for (id, title) in titles {
            hookTasksByID[id]?.title = title
            detectedTasksByID[id]?.title = title
        }
        publish()
    }

    func updateQuotas(_ windows: [QuotaWindow]) {
        snapshot.quotas = windows
        snapshot.refreshedAt = Date()
        snapshot.quotaError = nil
    }

    func setQuotaError(_ message: String) {
        snapshot.quotaError = message
    }

    private func removeExpiredTasks() {
        let now = Date()
        suppressedDetectedTaskIDs = suppressedDetectedTaskIDs.filter { _, expiresAt in expiresAt > now }
        hookTasksByID = hookTasksByID.filter { _, task in
            if task.phase == .completed || task.phase == .failed {
                return now.timeIntervalSince(task.updatedAt) < 12
            }
            return now.timeIntervalSince(task.updatedAt) < 60 * 60 * 8
        }
        publish()
    }

    private func publish() {
        let now = Date()
        var merged = detectedTasksByID.filter { !isDetectedTaskSuppressed($0.key, at: now) }
        for (id, task) in hookTasksByID { merged[id] = task }
        snapshot.tasks = merged.values
            .sorted { lhs, rhs in
                let lhsTerminal = lhs.phase == .completed || lhs.phase == .failed
                let rhsTerminal = rhs.phase == .completed || rhs.phase == .failed
                if lhsTerminal != rhsTerminal { return !lhsTerminal }
                return lhs.updatedAt > rhs.updatedAt
            }
            // Keep enough blocks for a few concurrent Codex projects. The
            // Touch Bar's equal-fill stack compresses them as this grows.
            .prefix(6)
            .map { $0 }
    }

    private func suppressDetectedTask(_ sessionID: String, at date: Date) {
        suppressedDetectedTaskIDs[sessionID] = date.addingTimeInterval(detectedTaskSuppression)
        detectedTasksByID.removeValue(forKey: sessionID)
    }

    private func isDetectedTaskSuppressed(_ sessionID: String, at date: Date) -> Bool {
        guard let expiresAt = suppressedDetectedTaskIDs[sessionID] else { return false }
        return expiresAt > date
    }
}
