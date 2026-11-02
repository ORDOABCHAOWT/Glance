import CodexTouchBarCore
import Foundation

private enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self { case .failed(let message): return message }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckFailure.failed(message) }
}

private func checkHookAllowlist() throws {
    let json: [String: Any] = [
        "session_id": "thr_secret",
        "turn_id": "turn_1",
        "hook_event_name": "PreToolUse",
        "cwd": "/Users/whitney/Secret Project",
        "tool_name": "mcp__server__browser",
        "transcript_path": "/secret/full/transcript.jsonl",
        "tool_input": ["command": "cat ~/.ssh/id_ed25519"],
        "tool_response": "private output",
        "model": "private-model",
        "permission_mode": "bypassPermissions",
    ]
    let data = try JSONSerialization.data(withJSONObject: json)
    let packet = try HookPacketParser.parse(data: data, now: Date(timeIntervalSince1970: 10))
    try expect(packet.workspaceName == "Secret Project", "workspace basename was not sanitized")
    try expect(packet.toolName == "browser", "tool display name was not sanitized")

    let text = String(decoding: try JSONEncoder().encode(packet), as: UTF8.self)
    for forbidden in ["transcript", "id_ed25519", "/Users/whitney", "private-model", "private output"] {
        try expect(!text.contains(forbidden), "sensitive field leaked into HookPacket: \(forbidden)")
    }
    try expect(packet.phase == .usingTool, "PreToolUse phase mapping failed")
}

private func checkRateLimits() throws {
    let response: [String: Any] = [
        "id": 2,
        "result": [
            "rateLimitsByLimitId": [
                "codex": [
                    "primary": ["usedPercent": 27, "windowDurationMins": 300, "resetsAt": 2_000_000_000],
                    "secondary": ["usedPercent": 61, "windowDurationMins": 10_080, "resetsAt": 2_000_100_000],
                ]
            ]
        ]
    ]
    let windows = try RateLimitParser.parseResponse(response).windows
    try expect(windows.map(\.kind) == [.fiveHour, .weekly], "quota windows were classified incorrectly")
    try expect(windows.map(\.remainingPercent) == [73, 39], "remaining quota calculation failed")

    let clamped: [String: Any] = [
        "result": ["rateLimits": ["primary": ["usedPercent": 140, "windowDurationMins": 300]]]
    ]
    let clampedWindow = try RateLimitParser.parseResponse(clamped).windows.first
    try expect(clampedWindow?.remainingPercent == 0, "quota clamp failed")
}

private func checkClaudeUsage() throws {
    let object: [String: Any] = [
        "version": 2,
        "samples": [["t": Date().timeIntervalSince1970 * 1000, "org": "opaque", "u": ["fh": 31, "sd": 68]]]
    ]
    let windows = try ClaudeUsageParser.parsePlanUsage(object)
    try expect(windows.map(\.kind) == [.fiveHour, .weekly], "Claude usage windows were not classified")
    try expect(windows.map(\.remainingPercent) == [69, 32], "Claude remaining usage was calculated incorrectly")
    do {
        _ = try ClaudeUsageParser.parsePlanUsage(["version": 2, "samples": [["t": Date().timeIntervalSince1970 * 1000, "org": "opaque", "u": ["fh": 140, "sd": 0]]]])
        throw CheckFailure.failed("invalid Claude percent was accepted")
    } catch ClaudeUsageParser.ParseError.missingUsage { }
    let oauth = try ClaudeUsageParser.parseOAuthUsage(["five_hour": ["utilization": 1], "seven_day": ["utilization": 0.5]])
    try expect(oauth.map(\.usedPercent) == [1, 1], "OAuth utilization percentages were scaled incorrectly")
}

private func checkClaudeInvalidDataAndTimes() throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    func history(_ value: Any, time: Double? = nil, version: Any = 2) -> [String: Any] {
        ["version": version, "samples": [["t": time ?? now.timeIntervalSince1970 * 1000, "org": "test-org", "u": ["fh": value, "sd": 20]]]]
    }
    func rejects(_ message: String, _ action: () throws -> Void) throws {
        do { try action() }
        catch is ClaudeUsageParser.ParseError { return }
        throw CheckFailure.failed(message)
    }
    for value: Any in [true, "12", -0.1, 100.1, Double.nan, Double.infinity] {
        try rejects("invalid history utilization accepted: \(value)") { _ = try ClaudeUsageParser.parseHistory(history(value), now: now) }
        try rejects("invalid OAuth utilization accepted: \(value)") { _ = try ClaudeUsageParser.parseOAuthUsage(["five_hour": ["utilization": value]]) }
    }
    for version: Any in [true, "2", 2.9, 1, Double.nan] {
        try rejects("invalid history version accepted") { _ = try ClaudeUsageParser.parseHistory(history(10, version: version), now: now) }
    }
    for time in [0, -1, Double.infinity, Double.nan, now.addingTimeInterval(301).timeIntervalSince1970 * 1000] {
        try rejects("invalid sample timestamp accepted") { _ = try ClaudeUsageParser.parseHistory(history(10, time: time), now: now) }
    }
    let old = ["t": now.addingTimeInterval(-3600).timeIntervalSince1970 * 1000, "org": "old", "u": ["fh": 80, "sd": 90]] as [String: Any]
    let recent = ["t": now.addingTimeInterval(-60).timeIntervalSince1970 * 1000, "org": "recent", "u": ["fh": 25, "sd": 35]] as [String: Any]
    let parsed = try ClaudeUsageParser.parseHistory(["version": 2, "samples": [recent, old]], now: now)
    try expect(parsed.organization == "recent" && parsed.sampledAt == now.addingTimeInterval(-60), "history must select actual latest sample, independent of array order")
    try expect(parsed.windows.map(\.remainingPercent) == [75, 65] && parsed.windows.allSatisfy { $0.resetsAt == nil }, "history must retain percentages and never invent reset times")
    let oauth = try ClaudeUsageParser.parseOAuthUsage([
        "five_hour": ["utilization": 0.5, "resets_at": "2033-05-18T03:33:20.250Z"],
        "seven_day": ["utilization": 100, "resets_at": "2033-05-18T03:33:20Z"]
    ])
    try expect(oauth.map(\.usedPercent) == [1, 100] && oauth.allSatisfy { $0.resetsAt != nil }, "OAuth percentages or fractional/plain ISO reset parsing failed")
    try rejects("unverified OAuth aliases accepted") { _ = try ClaudeUsageParser.parseOAuthUsage(["five_hour": ["usedPercent": 20]]) }
}

private func checkRefreshPolicy() throws {
    var policy = ClaudeRefreshPolicy()
    let t = Date(timeIntervalSince1970: 1_000)
    try expect(policy.begin(.foreground, now: t), "initial foreground refresh should start")
    try expect(!policy.begin(.foreground, now: t.addingTimeInterval(1)), "in-flight refresh was duplicated")
    policy.finish(success: false, now: t.addingTimeInterval(2))
    try expect(!policy.begin(.foreground, now: t.addingTimeInterval(31)), "failure backoff was ignored")
    try expect(policy.begin(.manual, now: t.addingTimeInterval(31)), "manual refresh did not bypass delay")
    policy.finish(success: true, now: t.addingTimeInterval(32))
    try expect(!policy.begin(.foreground, now: t.addingTimeInterval(60)), "foreground refresh ignored 30 second cadence")
    try expect(policy.begin(.periodic, now: t.addingTimeInterval(93)), "periodic refresh cadence failed")
    policy.finish(success: true, now: t.addingTimeInterval(94))
    try expect(!policy.begin(.periodic, now: t.addingTimeInterval(152)), "periodic refresh started before 60 seconds")
    try expect(policy.begin(.periodic, now: t.addingTimeInterval(153)), "periodic refresh failed at 60 seconds")
    policy.finish(success: true, now: t.addingTimeInterval(154))
    try expect(policy.begin(.foreground, now: t.addingTimeInterval(183)), "foreground refresh failed at 30 seconds")
    policy.finish(success: true, now: t.addingTimeInterval(184))
    for index in 1...8 {
        let attempt = t.addingTimeInterval(Double(200 + index))
        try expect(policy.begin(.manual, now: attempt), "manual attempt was unexpectedly blocked")
        policy.finish(success: false, now: attempt)
        let expected = min(900, 60 * pow(2, Double(index - 1)))
        try expect(policy.failureDeadline == attempt.addingTimeInterval(expected), "exponential backoff or cap failed")
    }
    try expect(!policy.begin(.foreground, now: t.addingTimeInterval(1000)), "backoff cap not enforced")
    try expect(policy.begin(.manual, now: t.addingTimeInterval(1000)), "manual could not bypass backoff")
    try expect(!policy.begin(.manual, now: t.addingTimeInterval(1001)), "manual duplicated an in-flight request")
    policy.finish(success: true, now: t.addingTimeInterval(1002))
    try expect(policy.failures == 0 && policy.lastSuccess == t.addingTimeInterval(1002), "successful refresh did not reset failures")
}

private func checkClaudeTaskStatuses() throws {
    let cases: [(String?, TaskPhase?)] = [("working", .thinking), ("running", .thinking), ("Using the browser", .usingTool), ("Awaiting input", .waitingInput), ("Approval required", .waitingApproval), ("idle", nil), ("Done", nil), ("completed", nil), ("unknown", nil), (nil, nil)]
    for (raw, expected) in cases { try expect(ClaudeTaskStatus.phase(for: raw) == expected, "Claude status mapping failed for \(raw ?? "nil")") }
    try expect(ClaudeTaskStatus.phase(forRowLabel: "Running 清理 Claude 缓存和文件", title: "清理 Claude 缓存和文件") == .thinking, "running row label was missed")
    try expect(ClaudeTaskStatus.phase(forRowLabel: "Idle 清理 Claude 缓存和文件", title: "清理 Claude 缓存和文件") == nil, "idle row was included")
    try expect(ClaudeTaskStatus.phase(forRowLabel: "Awaiting answer Email unsubscribe automation", title: "Email unsubscribe automation") == .waitingInput, "Cowork awaiting-answer row was missed")
    try expect(ClaudeTaskStatus.activeRow("Running 清理 Claude 缓存和文件")?.title == "清理 Claude 缓存和文件", "active row title was missed")
    try expect(ClaudeTaskStatus.activeRow("Idle 清理 Claude 缓存和文件") == nil, "idle row was misread as active")
    try expect(ClaudeTaskStatus.phase(forRowLabel: "Running another task", title: "清理 Claude 缓存和文件") == nil, "row status crossed titles")
}

private func checkClaudeSessionRegistry() throws {
    let hostID = "local_31d5ae3e-0bcc-4184-857a-b1b797259fe5"
    func registration(_ overrides: [String: Any?]) -> Data {
        var object: [String: Any] = [
            "pid": 73915,
            "sessionId": "da911531-5409-4717-a737-c10a798bbe54",
            "cwd": "/Users/whitney/Secret Project",
            "messagingSocketPath": "/private/tmp/secret.sock",
            "kind": "interactive",
            "entrypoint": "claude-desktop",
            "hostSessionId": hostID,
            "name": "日语学习应用 UI/交互优化",
            "status": "busy",
            "statusUpdatedAt": 1_790_405_336_222,
            "procStart": "Sat Sep 26 06:48:54 2026",
        ]
        for (key, value) in overrides { object[key] = value }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    let busy = ClaudeSessionRegistry.parse(registration([:]))
    try expect(busy?.pid == 73915 && busy?.hostSessionID == hostID, "desktop registration was not decoded")
    try expect(busy?.title == "日语学习应用 UI/交互优化", "registry title was not kept")
    try expect(busy?.phase == .thinking, "busy registry status must count as running")
    try expect(busy?.statusChangedAt == Date(timeIntervalSince1970: 1_790_405_336.222), "status time was not read as milliseconds")
    try expect(busy?.processStartedAt == Date(timeIntervalSince1970: 1_790_405_334), "procStart was not read as UTC")
    try expect(ClaudeSessionRegistry.parse(registration(["procStart": "Sat Sep  6 06:48:54 2026"]))?.processStartedAt != nil, "space-padded procStart was rejected")

    let phases: [(String?, String?, TaskPhase?)] = [
        ("busy", nil, .thinking), ("shell", nil, .usingTool),
        ("waiting", "permission prompt", .waitingApproval), ("waiting", "sandbox request", .waitingApproval),
        ("waiting", "input needed", .waitingInput), ("waiting", "dialog open", .waitingInput), ("waiting", nil, .waitingInput),
        ("idle", nil, nil), ("running", nil, nil), (nil, nil, nil),
    ]
    for (status, waitingFor, expected) in phases {
        try expect(ClaudeSessionRegistry.phase(status: status, waitingFor: waitingFor) == expected, "registry phase failed for \(status ?? "nil")/\(waitingFor ?? "nil")")
    }

    let rejected: [(String, [String: Any?])] = [
        ("CLI session", ["entrypoint": "cli"]),
        ("background session", ["kind": "bg"]),
        ("missing desktop ID", ["hostSessionId": nil]),
        ("malformed desktop ID", ["hostSessionId": "local_../../x"]),
        ("cloud session ID", ["hostSessionId": "session_abc"]),
        ("boolean pid", ["pid": true]),
        ("fractional pid", ["pid": 12.5]),
        ("negative pid", ["pid": -4]),
        ("string pid", ["pid": "73915"]),
    ]
    for (label, overrides) in rejected {
        try expect(ClaudeSessionRegistry.parse(registration(overrides)) == nil, "registry accepted \(label)")
    }
    try expect(ClaudeSessionRegistry.parse(Data("not json".utf8)) == nil, "registry accepted invalid JSON")
    try expect(ClaudeSessionRegistry.parse(Data(repeating: 0x20, count: ClaudeSessionRegistry.maximumFileSize + 1)) == nil, "registry accepted an oversized file")

    for name in ["line 1\nline 2", "  ", String(repeating: "长", count: 161)] {
        let record = ClaudeSessionRegistry.parse(registration(["name": name]))
        try expect(record != nil && record?.title == nil, "unsafe registry title was kept")
    }
    try expect(ClaudeSessionRegistry.parse(registration(["status": "idle"]))?.phase == nil, "idle session was shown as active")

    let link = ClaudeSessionRegistry.deepLink(forDesktopSession: hostID)?.absoluteString
    try expect(link == "claude://code/continue?session=\(hostID)", "Claude Desktop session link is wrong: \(link ?? "nil")")
    try expect(ClaudeSessionRegistry.deepLink(forDesktopSession: "local_x?session=last") == nil, "malformed session link was built")
}

do {
    try checkHookAllowlist()
    try checkRateLimits()
    try checkClaudeUsage()
    try checkClaudeInvalidDataAndTimes()
    try checkRefreshPolicy()
    try checkClaudeTaskStatuses()
    try checkClaudeSessionRegistry()
    print("CodexTouchBarCoreChecks passed")
} catch {
    fputs("CodexTouchBarCoreChecks failed: \(error)\n", stderr)
    exit(EXIT_FAILURE)
}

let modernCodex = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
let legacyCodex = "/Applications/ChatGPT.app/Contents/Resources/codex"
precondition(CodexExecutableLocator.find(applicationDirectories: ["/Applications"], isExecutable: { $0 == modernCodex || $0 == legacyCodex })?.path == modernCodex)
precondition(CodexExecutableLocator.find(applicationDirectories: ["/Applications"], isExecutable: { $0 == legacyCodex })?.path == legacyCodex)
precondition(CodexExecutableLocator.find(applicationDirectories: [], isExecutable: { $0 == "/opt/homebrew/bin/codex" })?.path == "/opt/homebrew/bin/codex")
precondition(CodexExecutableLocator.find(applicationDirectories: ["/Applications"], isExecutable: { _ in false }) == nil)
print("Codex executable discovery checks passed")
