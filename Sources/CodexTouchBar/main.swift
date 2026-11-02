import AppKit
import CodexTouchBarCore
import Foundation
import TouchBarPrivateBridge

if CommandLine.arguments.contains("--codex-usage-check") {
    let client = CodexAppServerClient()
    client.onQuotas = { windows in
        print(windows.map { "\($0.kind.rawValue)=\($0.remainingPercent)%" }.joined(separator: " "))
        client.stop()
        exit(windows.isEmpty ? EXIT_FAILURE : EXIT_SUCCESS)
    }
    client.onError = { message in fputs(message + "\n", stderr) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 55) {
        client.stop()
        print("Codex 用量检查超时")
        exit(EXIT_FAILURE)
    }
    client.start()
    RunLoop.main.run()
    exit(EXIT_FAILURE)
}

if CommandLine.arguments.contains("--resident-state-check") {
    let requestID = UUID().uuidString
    let center = DistributedNotificationCenter.default()
    let observer = center.addObserver(forName: Notification.Name("com.whitney.CodexTouchBar.state-response"), object: requestID, queue: .main) { note in
        if let info = note.userInfo, let data = try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
        exit(EXIT_SUCCESS)
    }
    center.postNotificationName(Notification.Name("com.whitney.CodexTouchBar.state-request"), object: requestID, userInfo: nil, deliverImmediately: true)
    RunLoop.current.run(until: Date().addingTimeInterval(8))
    center.removeObserver(observer)
    print("常驻进程未响应")
    exit(EXIT_FAILURE)
}

if let variantValue = CommandLine.arguments.firstIndex(of: "--variant").flatMap({ index in
    let next = CommandLine.arguments.index(after: index)
    return next < CommandLine.arguments.endIndex ? Int(CommandLine.arguments[next]) : nil
}) {
    VisualVariant.current = VisualVariant(rawValue: variantValue) ?? .balanced
}

if CommandLine.arguments.contains("--media-capability-check") {
    print(CTBMediaRemoteAvailable() ? "available" : "unavailable")
    exit(CTBMediaRemoteAvailable() ? EXIT_SUCCESS : EXIT_FAILURE)
}

if CommandLine.arguments.contains("--claude-task-check") {
    DispatchQueue.global().asyncAfter(deadline: .now() + 12) {
        print("Claude 任务检查超时")
        exit(EXIT_FAILURE)
    }
    Task { @MainActor in
        // Counts and phases only; titles stay out of diagnostic output.
        let records = ClaudeSessionMonitor.liveRecords()
        let active = records.compactMap(\.phase)
        print("Code 会话登记：\(records.count) 个打开，\(active.count) 个活动")
        print("登记状态：\(active.map(\.rawValue).joined(separator: ","))")
        let monitor = ClaudeSidebarMonitor()
        let tasks = monitor.scan()
        print("辅助功能：\(monitor.isTrusted ? "已授权" : "未授权")")
        print("窗口/侧栏节点/标题行：\(monitor.diagnosticCounts.windows)/\(monitor.diagnosticCounts.sidebarNodes)/\(monitor.diagnosticCounts.titledRows)")
        print("活动侧栏任务：\(tasks.count)")
        print("状态：\(tasks.map { $0.phase.rawValue }.joined(separator: ","))")
        exit(monitor.isTrusted || !records.isEmpty ? EXIT_SUCCESS : EXIT_FAILURE)
    }
    dispatchMain()
}

if CommandLine.arguments.contains("--claude-usage-check") {
    let allowPrompt = CommandLine.arguments.contains("--allow-keychain-prompt")
    DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
        print("Claude 用量检查超时")
        exit(EXIT_FAILURE)
    }
    Task.detached {
        do {
            let windows = try await ClaudeOAuthUsageClient().fetch(allowAuthenticationUI: allowPrompt) { stage in
                print(stage); fflush(stdout)
            }
            guard !windows.isEmpty else { print("Claude 用量检查失败"); exit(EXIT_FAILURE) }
            print(windows.map { "\($0.kind.rawValue)=\($0.remainingPercent)%" }.joined(separator: " "))
            exit(EXIT_SUCCESS)
        } catch {
            print((error as? LocalizedError)?.errorDescription ?? "Claude 用量检查失败")
            exit(EXIT_FAILURE)
        }
    }
    dispatchMain()
}

if CommandLine.arguments.contains("--activity-probe") {
    let rows = CTBReadRecentCodexActivity(120)
    let titledRows = rows.filter { row in
        guard let title = row["rawTitle"] as? String else { return false }
        return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    for row in titledRows.prefix(3) {
        if let id = row["id"] as? String { print(id) }
    }
    exit(titledRows.isEmpty ? EXIT_FAILURE : EXIT_SUCCESS)
}

if CommandLine.arguments.contains("--hook") {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    if let packet = try? HookPacketParser.parse(data: data) {
        HookSocketClient.send(packet)
    }
    exit(EXIT_SUCCESS)
}

if CommandLine.arguments.contains("--install-hook") {
    do {
        let executable = Bundle.main.executablePath ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardized.path
        try HookConfiguration.install(executablePath: executable)
        print("CodexTouchBar status connection installed")
        exit(EXIT_SUCCESS)
    } catch {
        fputs("CodexTouchBar hook install failed: \(error.localizedDescription)\n", stderr)
        exit(EXIT_FAILURE)
    }
}

if CommandLine.arguments.contains("--uninstall-hook") {
    do {
        try HookConfiguration.uninstall()
        print("CodexTouchBar status connection removed")
        exit(EXIT_SUCCESS)
    } catch {
        fputs("CodexTouchBar hook removal failed: \(error.localizedDescription)\n", stderr)
        exit(EXIT_FAILURE)
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}
