import CodexTouchBarCore
import Foundation

/// Claude Desktop's local plan history is a usage history fallback. It is
/// intentionally separate from Codex's store and never reads credentials,
/// prompts, transcripts, or cookies.
@MainActor
final class ClaudeStore {
    var onChange: ((DashboardSnapshot) -> Void)?
    private(set) var snapshot = DashboardSnapshot(provider: .claude)
    private var timer: Timer?
    private var taskTimer: Timer?
    private var policy = ClaudeRefreshPolicy()
    private var refreshTask: Task<Void, Never>?
    private(set) var isActive = false
    private(set) var lastErrorCategory: String?
    private let oauthClient = ClaudeOAuthUsageClient()
    private let sessionMonitor = ClaudeSessionMonitor()
    private var sessionTasks: [TaskSnapshot] = []
    private let historyURL: URL

    init(fileManager: FileManager = .default) {
        historyURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
    }

    func start() {
        sessionMonitor.onTasks = { [weak self] tasks in
            Task { @MainActor [weak self] in
                self?.sessionTasks = tasks
                self?.publishTasks()
            }
        }
        sessionMonitor.start()
        loadHistoryOnly()
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        timer?.invalidate()
        timer = nil
        taskTimer?.invalidate(); taskTimer = nil
        guard active else { return }
        refresh(reason: .foreground)
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(reason: .periodic) }
        }
        taskTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in Task { @MainActor in self?.publishTasks() } }
    }

    func stop() {
        sessionMonitor.stop()
        timer?.invalidate()
        timer = nil
        taskTimer?.invalidate(); taskTimer = nil
        refreshTask?.cancel()
        if policy.inFlight { policy.finish(success: false, now: Date()) }
    }

    func refresh(force: Bool = false, allowAuthenticationUI: Bool = false, now: Date = Date(), reason: ClaudeRefreshPolicy.Reason = .foreground) {
        guard isActive || force else { return }
        let selectedReason: ClaudeRefreshPolicy.Reason = force ? .manual : reason
        guard policy.begin(selectedReason, now: now) else { return }
        if refreshTask == nil {
            refreshTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let quotas = try await self.oauthClient.fetch(allowAuthenticationUI: allowAuthenticationUI)
                    await MainActor.run { self.apply(quota: quotas, now: Date(), error: nil) }
                } catch {
                    await MainActor.run { self.applyHistoryFallback(now: Date(), error: error) }
                }
            }
        }
    }

    private func apply(quota: [QuotaWindow], now: Date, error: String?) {
        refreshTask = nil
        policy.finish(success: error == nil, now: now)
        snapshot = DashboardSnapshot(provider: .claude, tasks: allTasks(), quotas: quota, refreshedAt: now, refreshError: error, quotaSource: "Claude Code 登录账户")
        lastErrorCategory = error == nil ? nil : "unknown"
        onChange?(snapshot)
    }

    private func applyHistoryFallback(now: Date, error: Error) {
        refreshTask = nil
        let refreshFailure = failureMessage(error)
        lastErrorCategory = errorCategory(error)
        policy.finish(success: false, now: now)
        do {
            let data = try Data(contentsOf: historyURL, options: [.mappedIfSafe])
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let object else { throw ClaudeError.invalidResponse }
            let history = try ClaudeUsageParser.parseHistory(object, now: now)
            if snapshot.quotas.isEmpty || history.sampledAt > (snapshot.refreshedAt ?? .distantPast) {
                snapshot.quotas = history.windows
                snapshot.refreshedAt = history.sampledAt
                snapshot.quotaSource = "Claude 桌面历史"
            }
        } catch {
            // Preserve the actionable authentication/network failure even when
            // the optional history file is absent or malformed.
        }
        snapshot.refreshError = refreshFailure
        snapshot.tasks = allTasks()
        onChange?(snapshot)
    }

    private func loadHistoryOnly() {
        let data = try? Data(contentsOf: historyURL, options: [.mappedIfSafe])
        let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let history = object.flatMap { try? ClaudeUsageParser.parseHistory($0, now: Date()) }
        snapshot = DashboardSnapshot(provider: .claude, tasks: allTasks(), quotas: history?.windows ?? [], refreshedAt: history?.sampledAt, refreshError: history == nil ? "Claude 用量历史暂不可用" : "Claude 用量历史（可能已过期）", quotaSource: history == nil ? nil : "Claude 桌面历史")
        lastErrorCategory = history == nil ? "history_unavailable" : "history_fallback"
        onChange?(snapshot)
    }

    func publishTasks() { snapshot.tasks = allTasks(); onChange?(snapshot) }

    private func allTasks() -> [TaskSnapshot] {
        Array(sessionTasks.prefix(12))
    }

    private func failureMessage(_ error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription { return localized }
        if (error as? CocoaError)?.code == .fileNoSuchFile { return "Claude 用量暂不可用（未找到本地用量历史）" }
        return "Claude 用量暂不可用（数据格式或读取失败）"
    }

    private func errorCategory(_ error: Error) -> String {
        switch error {
        case ClaudeOAuthUsageClient.ClientError.accessRequired: return "keychain_access"
        case ClaudeOAuthUsageClient.ClientError.missingCredentials: return "credentials_missing"
        case ClaudeOAuthUsageClient.ClientError.expired: return "credentials_expired"
        case ClaudeOAuthUsageClient.ClientError.unauthorized: return "unauthorized"
        case ClaudeOAuthUsageClient.ClientError.rateLimited: return "rate_limited"
        default: return "network_or_response"
        }
    }

    enum ClaudeError: Error { case invalidResponse }
}
