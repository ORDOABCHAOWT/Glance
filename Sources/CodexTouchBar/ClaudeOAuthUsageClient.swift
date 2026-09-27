import CodexTouchBarCore
import Foundation
import Security

/// Reads the Claude Code OAuth token from Keychain without prompting. The
/// token exists only in memory for the duration of one request and is never
/// logged, persisted, or exposed to the UI.
final class ClaudeOAuthUsageClient {
    private static let keychainQueue = DispatchQueue(label: "com.whitney.CodexTouchBar.claude-keychain")
    enum ClientError: LocalizedError {
        case credentialsUnavailable, accessRequired, missingCredentials
        case expired
        case unauthorized
        case rateLimited
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .credentialsUnavailable: return "Claude 登录凭据不可用，请在 Claude Code 中重新登录"
            case .accessRequired: return "请在菜单中连接 Claude 用量并允许钥匙串访问"
            case .missingCredentials: return "未找到 Claude 登录凭据，请在 Claude Code 中重新登录"
            case .expired: return "Claude 登录已过期，请在 Claude Code 中重新登录"
            case .unauthorized: return "Claude 用量请求未获授权，请重新登录"
            case .rateLimited: return "Claude 用量请求过于频繁，稍后自动重试"
            case .invalidResponse: return "Claude 用量服务返回了无法识别的数据"
            }
        }
    }

    private struct Credentials: Decodable {
        struct OAuth: Decodable {
            let accessToken: String
            let expiresAt: Double?
        }
        let claudeAiOauth: OAuth
    }

    func fetch(allowAuthenticationUI: Bool = false, progress: ((String) -> Void)? = nil) async throws -> [QuotaWindow] {
        do {
            return try await fetchOnce(allowAuthenticationUI: allowAuthenticationUI, progress: progress)
        } catch let error as ClientError where error == .expired || error == .unauthorized {
            // Claude Desktop keeps its own login, so Claude Code's token goes
            // stale unless the CLI runs. Let Claude Code refresh it, then retry.
            guard await ClaudeCodeTokenRefresher.refresh(progress: progress) else { throw error }
            return try await fetchOnce(allowAuthenticationUI: allowAuthenticationUI, progress: progress)
        }
    }

    private func fetchOnce(allowAuthenticationUI: Bool, progress: ((String) -> Void)?) async throws -> [QuotaWindow] {
        progress?("开始读取凭据")
        let (token, expiresAt) = try readCredentials(allowAuthenticationUI: allowAuthenticationUI, progress: progress)
        progress?("凭据读取完成")
        if let expiresAt, expiresAt.isFinite, expiresAt > 0, Date().timeIntervalSince1970 * 1000 >= expiresAt {
            throw ClientError.expired
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 8
        let session = URLSession(configuration: configuration, delegate: RedirectDenyingDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        progress?("开始请求用量")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        progress?("收到 HTTP \(http.statusCode)")
        if http.statusCode == 401 || http.statusCode == 403 { throw ClientError.unauthorized }
        if http.statusCode == 429 { throw ClientError.rateLimited }
        guard (200..<300).contains(http.statusCode), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientError.invalidResponse
        }
        return try ClaudeUsageParser.parseOAuthUsage(object)
    }

    private func readCredentials(allowAuthenticationUI: Bool, progress: ((String) -> Void)? = nil) throws -> (String, Double?) {
        // Claude Code writes this item with /usr/bin/security, so the item's
        // access list trusts that tool. Reading through it needs no prompt and
        // survives the ad-hoc re-signing that invalidates "Always Allow" for
        // this app. The in-process lookup remains as a fallback.
        switch Self.readWithSecurityTool() {
        case .found(let data):
            progress?("钥匙串读取成功")
            return try Self.decode(data)
        case .notFound:
            throw ClientError.missingCredentials
        case .failed:
            progress?("钥匙串工具读取失败，改用应用内读取")
        }
        return try readInProcess(allowAuthenticationUI: allowAuthenticationUI, progress: progress)
    }

    private enum SecurityToolResult { case found(Data), notFound, failed }

    private static func readWithSecurityTool() -> SecurityToolResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-a", NSUserName(), "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return .failed }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus == 44 { return .notFound }  // errSecItemNotFound
        guard process.terminationStatus == 0, !data.isEmpty else { return .failed }
        return .found(data)
    }

    private static func decode(_ data: Data) throws -> (String, Double?) {
        let credentials: Credentials
        do { credentials = try JSONDecoder().decode(Credentials.self, from: data) }
        catch { throw ClientError.credentialsUnavailable }
        guard !credentials.claudeAiOauth.accessToken.isEmpty else { throw ClientError.credentialsUnavailable }
        return (credentials.claudeAiOauth.accessToken, credentials.claudeAiOauth.expiresAt)
    }

    private func readInProcess(allowAuthenticationUI: Bool, progress: ((String) -> Void)?) throws -> (String, Double?) {
        // SecKeychainFindGenericPassword matches the native lookup used by
        // macOS Keychain tooling. The interaction flag is process-global, so
        // serialize this short lookup and restore the caller's setting.
        let service = Array("Claude Code-credentials".utf8)
        let account = Array(NSUserName().utf8)
        var passwordLength: UInt32 = 0
        var passwordData: UnsafeMutableRawPointer?
        let status: OSStatus = Self.keychainQueue.sync {
            var previous = DarwinBoolean(true)
            guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
                  SecKeychainSetUserInteractionAllowed(allowAuthenticationUI) == errSecSuccess else {
                return errSecInteractionNotAllowed
            }
            defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
            return SecKeychainFindGenericPassword(nil, UInt32(service.count), service, UInt32(account.count), account, &passwordLength, &passwordData, nil)
        }
        progress?("钥匙串状态 \(status)")
        if status == errSecInteractionNotAllowed || (!allowAuthenticationUI && status == errSecAuthFailed) { throw ClientError.accessRequired }
        if status == errSecItemNotFound { throw ClientError.missingCredentials }
        guard status == errSecSuccess, let passwordData else { throw ClientError.credentialsUnavailable }
        let data = Data(bytes: passwordData, count: Int(passwordLength))
        SecKeychainItemFreeContent(nil, passwordData)
        guard passwordLength > 0 else { throw ClientError.credentialsUnavailable }
        return try Self.decode(data)
    }
}

/// Lets Claude Code refresh its own OAuth token. `claude -p /usage` is a local
/// command: it sends no model request and creates no saved session, but runs
/// Claude Code's normal token refresh, which rewrites the Keychain item.
enum ClaudeCodeTokenRefresher {
    private static let lock = NSLock()
    private static var lastAttempt = Date.distantPast
    private static let minimumInterval: TimeInterval = 5 * 60

    static func refresh(progress: ((String) -> Void)? = nil) async -> Bool {
        let allowed = lock.withLock {
            guard Date().timeIntervalSince(lastAttempt) >= minimumInterval else { return false }
            lastAttempt = Date()
            return true
        }
        guard allowed, let executable = claudeExecutable() else { return false }
        progress?("请 Claude Code 刷新登录")
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: run(executable))
            }
        }
    }

    private static func run(_ executable: URL) -> Bool {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-p", "/usage", "--no-session-persistence"]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "USER": NSUserName(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:\(executable.deletingLastPathComponent().path)",
            "TERM": "dumb",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return false }
        guard finished.wait(timeout: .now() + 45) == .success else {
            process.terminate()
            return false
        }
        return process.terminationStatus == 0
    }

    private static func claudeExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }
}

private final class RedirectDenyingDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
