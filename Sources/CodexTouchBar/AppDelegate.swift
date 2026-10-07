import AppKit
import CodexTouchBarCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = StatusStore()
    private var socketServer: HookSocketServer?
    private var codexClient: CodexAppServerClient?
    private var activityMonitor: CodexActivityMonitor?
    private let claudeStore = ClaudeStore()
    private let claudeSidebarMonitor = ClaudeSidebarMonitor()
    private let touchBarController = TouchBarController()
    private var previewController: PreviewWindowController?
    private var statusItem: NSStatusItem?
    private var diagnosticObserver: NSObjectProtocol?
    private var connectionMenuItem: NSMenuItem?
    private var codexSnapshot = DashboardSnapshot(provider: .codex)
    private var claudeSnapshot = DashboardSnapshot(provider: .claude)
    private var previewOnly = false
    private var pinnedProvider: TaskProvider?
    private var lastSupportedProvider: TaskProvider = .codex
    private var currentProvider: TaskProvider? {
        let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if ["com.openai.codex", "com.openai.chatgpt"].contains(id) { return .codex }
        if ["com.anthropic.claudefordesktop", "com.anthropic.claude"].contains(id) { return .claude }
        return nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        previewOnly = CommandLine.arguments.contains("--preview-only")
        pinnedProvider = argumentValue(after: "--provider").flatMap { TaskProvider(rawValue: $0) }
        if !previewOnly {
            diagnosticObserver = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.whitney.CodexTouchBar.state-request"), object: nil, queue: .main) { [weak self] note in
                guard let requestID = note.object as? String, UUID(uuidString: requestID) != nil else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let state: [String: Any] = [
                        "pid": ProcessInfo.processInfo.processIdentifier,
                        "foreground": self.currentProvider?.rawValue ?? "other",
                        "lastProvider": self.lastSupportedProvider.rawValue,
                        "claudeActive": self.claudeStore.isActive,
                        "claudeTasks": self.claudeSnapshot.tasks.count,
                        "visibleButtons": self.touchBarController.visibleTaskCount,
                        "accessibility": self.claudeSidebarMonitor.isTrusted,
                        "sidebarNodes": self.claudeSidebarMonitor.diagnosticCounts.sidebarNodes,
                        "titledRows": self.claudeSidebarMonitor.diagnosticCounts.titledRows
                        ,"quotaSource": self.claudeSnapshot.quotaSource ?? "none"
                        ,"quotaStale": self.claudeSnapshot.provider == .claude && (self.claudeSnapshot.refreshError != nil || self.claudeSnapshot.quotaSource == "Claude 桌面历史" || self.claudeSnapshot.refreshedAt.map { Date().timeIntervalSince($0) > 120 } ?? true)
                        ,"quotaLastUpdated": self.claudeSnapshot.refreshedAt?.ISO8601Format() ?? "none"
                        ,"quotaErrorCategory": self.claudeStore.lastErrorCategory ?? "none"
                        ,"quotaError": self.claudeSnapshot.refreshError ?? "none"
                    ]
                    DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.whitney.CodexTouchBar.state-response"), object: requestID, userInfo: state, deliverImmediately: true)
                }
            }
        }

        if !previewOnly {
            socketServer = HookSocketServer()
            codexClient = CodexAppServerClient()
            activityMonitor = CodexActivityMonitor()
        }
        bindData()
        if !previewOnly {
            do {
                try socketServer?.start { [weak self] packet in
                    Task { @MainActor in self?.store.accept(packet) }
                }
            } catch {
                store.setQuotaError("任务连接启动失败")
            }
            codexClient?.start(); activityMonitor?.start()
        }

        if !previewOnly { touchBarController.install() }
        claudeStore.start()
        foregroundChanged(currentProvider)
        store.onChange?(store.snapshot)

        if CommandLine.arguments.contains("--preview") || !touchBarController.privateAPIAvailable {
            showPreviewWindow()
        }
        if CommandLine.arguments.contains("--demo") {
            installDemoTasks()
        }
        if let snapshotPath = argumentValue(after: "--snapshot") {
            let preview = ensurePreviewController()
            preview.show()
            let delay = Double(argumentValue(after: "--snapshot-delay") ?? "8") ?? 8
            DispatchQueue.main.asyncAfter(deadline: .now() + max(1, min(30, delay))) { [weak self] in
                guard let self else { return }
                try? self.previewController?.renderPNG(to: URL(fileURLWithPath: snapshotPath))
                NSApp.terminate(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let diagnosticObserver { DistributedNotificationCenter.default().removeObserver(diagnosticObserver) }
        codexClient?.stop(); activityMonitor?.stop()
        claudeStore.stop()
        socketServer?.stop()
        if !previewOnly { touchBarController.uninstall() }
    }

    private func bindData() {
        store.onChange = { [weak self] snapshot in
            guard let self else { return }
            self.codexSnapshot = snapshot
            self.updateVisibleSnapshot()
        }
        codexClient?.onQuotas = { [weak self] windows in self?.store.updateQuotas(windows) }
        codexClient?.onThreadTitles = { [weak self] titles in self?.store.updateThreadTitles(titles) }
        codexClient?.onError = { [weak self] message in self?.store.setQuotaError(message) }
        activityMonitor?.onTasks = { [weak self] tasks in self?.store.updateDetectedTasks(tasks) }
        claudeStore.onChange = { [weak self] snapshot in
            guard let self else { return }
            self.claudeSnapshot = snapshot
            // The status menu and preview can temporarily make our own app
            // frontmost while the last selected provider is still Claude.
            if self.currentProvider == .claude || self.lastSupportedProvider == .claude || self.pinnedProvider == .claude {
                // Code sessions come from Claude Code's session registry with
                // an exact session link. A sidebar row with the same title is
                // the same task, so the sidebar only adds chats and Cowork.
                let registryTitles = Set(snapshot.tasks.map(\.title))
                let sidebar = self.claudeSidebarMonitor.scan().filter { !registryTitles.contains($0.title) }
                self.claudeSnapshot.tasks = Array((snapshot.tasks + sidebar).prefix(12))
                self.claudeSnapshot.taskError = self.claudeSidebarMonitor.permissionMessage
            }
            self.updateVisibleSnapshot()
        }
        touchBarController.onFrontmostProviderChanged = { [weak self] provider in
            self?.foregroundChanged(provider)
        }
        touchBarController.onTaskRouteSelected = { [weak self] route in
            self?.handleRoute(route)
        }
        touchBarController.onRefreshRequested = { [weak self] in self?.claudeStore.refresh(force: true, allowAuthenticationUI: true) }
    }

    private func foregroundChanged(_ provider: TaskProvider?) {
        if let provider { lastSupportedProvider = provider }
        claudeStore.setActive(!previewOnly && provider == .claude)
        if provider == .claude { claudeStore.publishTasks() }
        updateVisibleSnapshot()
    }

    private func handleRoute(_ route: TaskRoute) {
        guard route.supported else { routeFailed(route); return }
        let success = route.requiresAccessibility ? claudeSidebarMonitor.press(identifier: route.identifier) : ThreadNavigator.open(route: route)
        if !success && route.provider == .codex {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                if !ThreadNavigator.open(route: route) { self?.routeFailed(route) }
            }
        } else if !success {
            routeFailed(route)
        }
    }
    private func routeFailed(_ route: TaskRoute) {
        NSSound.beep()
        if route.provider == .claude { claudeSnapshot.taskError = "Claude 任务导航暂不可用，请重新打开侧栏" }
        else { codexSnapshot.taskError = "Codex 任务导航暂不可用" }
        updateVisibleSnapshot()
    }

    private func updateVisibleSnapshot() {
        // Opening our preview must not replace its last provider with Codex.
        let physical = (currentProvider ?? lastSupportedProvider) == .claude ? claudeSnapshot : codexSnapshot
        let preview = (pinnedProvider ?? lastSupportedProvider) == .claude ? claudeSnapshot : codexSnapshot
        touchBarController.update(physical)
        previewController?.update(preview)
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "Glance")
        item.button?.toolTip = "Glance"
        let menu = NSMenu()

        let preview = NSMenuItem(title: "显示界面预览", action: #selector(showPreview), keyEquivalent: "p")
        preview.target = self
        menu.addItem(preview)

        let present = NSMenuItem(title: "重新显示 Touch Bar", action: #selector(presentTouchBar), keyEquivalent: "t")
        present.target = self
        menu.addItem(present)
        menu.addItem(.separator())

        let claudeAccess = NSMenuItem(title: "启用 Claude 侧栏任务访问", action: #selector(requestClaudeAccess), keyEquivalent: "")
        claudeAccess.target = self
        menu.addItem(claudeAccess)
        let refreshClaude = NSMenuItem(title: "刷新 Claude 用量", action: #selector(refreshClaudeUsage), keyEquivalent: "")
        refreshClaude.target = self; menu.addItem(refreshClaude)
        let connectClaude = NSMenuItem(title: "连接 Claude 用量…", action: #selector(connectClaudeUsage), keyEquivalent: "")
        connectClaude.target = self; menu.addItem(connectClaude)

        let connection = NSMenuItem(title: "", action: #selector(toggleConnection), keyEquivalent: "")
        connection.target = self
        menu.addItem(connection)
        connectionMenuItem = connection
        refreshConnectionMenuTitle()

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 Glance", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    @objc private func requestClaudeAccess() {
        claudeSidebarMonitor.requestPermission()
        if let message = claudeSidebarMonitor.permissionMessage { showConnectionAlert(success: false, message: message) }
    }
    @objc private func refreshClaudeUsage() { claudeStore.refresh(force: true, allowAuthenticationUI: true) }
    @objc private func connectClaudeUsage() { claudeStore.refresh(force: true, allowAuthenticationUI: true) }

    @objc private func showPreview() {
        showPreviewWindow()
    }

    @objc private func presentTouchBar() {
        touchBarController.present()
    }

    @objc private func toggleConnection() {
        do {
            if HookConfiguration.isInstalled() {
                try HookConfiguration.uninstall()
            } else {
                try HookConfiguration.install(executablePath: Bundle.main.executablePath ?? CommandLine.arguments[0])
            }
            refreshConnectionMenuTitle()
            showConnectionAlert(success: true, message: HookConfiguration.isInstalled()
                ? "Codex 状态连接已安装。新发生的任务活动会立即显示。"
                : "Codex 状态连接已移除。额度显示不受影响。")
        } catch {
            showConnectionAlert(success: false, message: error.localizedDescription)
        }
    }

    private func refreshConnectionMenuTitle() {
        connectionMenuItem?.title = HookConfiguration.isInstalled()
            ? "移除 Codex 状态连接"
            : "安装 Codex 状态连接"
    }

    private func showConnectionAlert(success: Bool, message: String) {
        let alert = NSAlert()
        alert.alertStyle = success ? .informational : .warning
        alert.messageText = success ? "Glance" : "操作未完成"
        alert.informativeText = message
        alert.runModal()
    }

    private func installDemoTasks() {
        let now = Date()
        let samples = [
            HookPacket(sessionID: "demo-1", turnID: "turn-1", workspaceName: "CodexTouchBar", eventName: "PreToolUse", toolName: "swift", occurredAt: now.addingTimeInterval(-83)),
            HookPacket(sessionID: "demo-2", turnID: "turn-2", workspaceName: "图标优化", eventName: "PermissionRequest", toolName: nil, occurredAt: now.addingTimeInterval(-41)),
            HookPacket(sessionID: "demo-3", turnID: "turn-3", workspaceName: "安全检查", eventName: "UserPromptSubmit", toolName: nil, occurredAt: now.addingTimeInterval(-12)),
        ]
        samples.forEach(store.accept)
    }

    private func ensurePreviewController() -> PreviewWindowController {
        if let previewController { return previewController }
        let controller = PreviewWindowController()
        controller.onTaskRouteSelected = { [weak self] route in
            self?.handleRoute(route)
        }
        controller.onRefreshRequested = { [weak self] in self?.claudeStore.refresh(force: true, allowAuthenticationUI: true) }
        controller.update((pinnedProvider ?? lastSupportedProvider) == .claude ? claudeSnapshot : codexSnapshot)
        previewController = controller
        return controller
    }

    private func showPreviewWindow() {
        ensurePreviewController().show()
    }

    private func argumentValue(after flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag) else { return nil }
        let next = CommandLine.arguments.index(after: index)
        guard next < CommandLine.arguments.endIndex else { return nil }
        return CommandLine.arguments[next]
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
