import CodexTouchBarCore
import Foundation

final class CodexAppServerClient {
    var onQuotas: (([QuotaWindow]) -> Void)?
    var onThreadTitles: (([String: String]) -> Void)?
    var onError: ((String) -> Void)?

    private enum RequestKind { case initialize, rateLimits, threadList }
    private let queue = DispatchQueue(label: "com.whitney.CodexTouchBar.app-server")
    private var process: Process?
    private var input: FileHandle?
    private var outputBuffer = Data()
    private var requestKinds: [Int: RequestKind] = [:]
    private var nextRequestID = 1
    private var timer: DispatchSourceTimer?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var connectionID = UUID()
    private var requestDeadlines: [Int: Date] = [:]
    private var lastRefresh = Date.distantPast
    private let executableResolver: () -> URL?

    init(executableResolver: @escaping () -> URL? = CodexExecutableLocator.find) {
        self.executableResolver = executableResolver
    }
    private var isInitialized = false
    private var isStopped = false

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isStopped = false
            guard self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 5, repeating: 5)
            timer.setEventHandler { [weak self] in self?.maintainConnection() }
            timer.resume()
            self.timer = timer
            self.launchIfNeeded()
        }
    }

    func stop() {
        queue.sync {
            isStopped = true
            timer?.cancel()
            timer = nil
            resetConnection()
        }
    }

    deinit { stop() }

    func requestRefresh() {
        queue.async { [weak self] in
            guard let self, !self.isStopped else { return }
            if self.isInitialized { self.refresh() }
            else { self.launchIfNeeded() }
        }
    }

    private func resetConnection() {
        connectionID = UUID()
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        stdoutHandle = nil
        stderrHandle = nil
        input?.closeFile()
        input = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        isInitialized = false
        outputBuffer.removeAll()
        requestKinds.removeAll()
        requestDeadlines.removeAll()
    }

    private func maintainConnection() {
        guard !isStopped else { return }
        if requestDeadlines.values.contains(where: { $0 < Date() }) {
            emitError("Codex 数据连接超时，正在重连")
            resetConnection()
        }
        if process?.isRunning != true { launchIfNeeded() }
        else if isInitialized && Date().timeIntervalSince(lastRefresh) >= 60 { refresh() }
    }

    private func launchIfNeeded() {
        guard !isStopped, process?.isRunning != true else { return }
        resetConnection()
        guard let executable = executableResolver() else {
            emitError("找不到 Codex App Server")
            return
        }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let generation = connectionID
        process.terminationHandler = { [weak self] _ in
            self?.queue.async {
                guard let self, self.connectionID == generation, !self.isStopped else { return }
                self.resetConnection()
                self.emitError("Codex 数据连接已断开，正在重连")
            }
        }
        stdoutHandle = stdoutPipe.fileHandleForReading
        stderrHandle = stderrPipe.fileHandleForReading
        stdoutHandle?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self?.queue.async {
                guard let self, self.connectionID == generation else { return }
                self.consume(data)
            }
        }
        stderrHandle?.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }

        do {
            try process.run()
            self.process = process
            input = stdinPipe.fileHandleForWriting
            isInitialized = false
            sendInitialize()
        } catch {
            resetConnection()
            emitError("无法启动 Codex App Server，正在重试")
        }
    }

    private func sendInitialize() {
        let id = allocate(.initialize)
        send([
            "method": "initialize",
            "id": id,
            "params": [
                "clientInfo": [
                    "name": "codex_touch_bar",
                    "title": "Codex Touch Bar",
                    "version": "0.1.0",
                ],
                "capabilities": [
                    "experimentalApi": false,
                    "optOutNotificationMethods": [
                        "item/agentMessage/delta",
                        "item/reasoning/textDelta",
                        "item/commandExecution/outputDelta",
                    ],
                ],
            ],
        ])
    }

    private func beginPolling() {
        guard !isInitialized else { return }
        isInitialized = true
        refresh()

    }

    private func refresh() {
        guard !requestKinds.values.contains(where: { $0 == .rateLimits }) else { return }
        lastRefresh = Date()
        let rateID = allocate(.rateLimits)
        send(["method": "account/rateLimits/read", "id": rateID, "params": [:]])
        let listID = allocate(.threadList)
        send([
            "method": "thread/list",
            "id": listID,
            "params": [
                "limit": 100,
                "sortKey": "updated_at",
                "sortDirection": "desc",
                "archived": false,
                "useStateDbOnly": true,
                "sourceKinds": ["appServer", "cli", "vscode"],
            ],
        ])
    }

    private func consume(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer.prefix(upTo: newline)
            outputBuffer.removeSubrange(...newline)
            guard
                !line.isEmpty,
                let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            else { continue }
            handle(object)
        }
    }

    private func handle(_ object: [String: Any]) {
        if let notification = RateLimitParser.parseUpdatedNotification(object) {
            emitQuotas(notification.windows)
            return
        }
        guard let id = (object["id"] as? NSNumber)?.intValue ?? object["id"] as? Int else { return }
        guard let kind = requestKinds.removeValue(forKey: id) else { return }
        requestDeadlines.removeValue(forKey: id)
        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Codex 接口返回错误"
            emitError(message)
            if kind == .initialize { resetConnection() }
            return
        }
        switch kind {
        case .initialize:
            send(["method": "initialized", "params": [:]])
            beginPolling()
        case .rateLimits:
            do { emitQuotas(try RateLimitParser.parseResponse(object).windows) }
            catch { emitError("暂时无法读取额度") }
        case .threadList:
            emitThreadTitles(parseThreadTitles(object))
        }
    }

    private func parseThreadTitles(_ object: [String: Any]) -> [String: String] {
        guard
            let result = object["result"] as? [String: Any],
            let data = result["data"] as? [[String: Any]]
        else { return [:] }
        var titles: [String: String] = [:]
        for thread in data {
            guard let id = thread["id"] as? String else { continue }
            // title, preview, and firstUserMessage can all be derived from
            // request body content. Only an explicit thread name is safe to
            // use as a Touch Bar project label.
            let rawTitle = (thread["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let rawTitle, !rawTitle.isEmpty else { continue }
            titles[id] = CodexActivityMonitor.displayTitle(from: rawTitle, fallback: "Codex")
        }
        return titles
    }

    private func allocate(_ kind: RequestKind) -> Int {
        defer { nextRequestID += 1 }
        requestKinds[nextRequestID] = kind
        requestDeadlines[nextRequestID] = Date().addingTimeInterval(45)
        return nextRequestID
    }

    private func send(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object), let input else { return }
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        do { try input.write(contentsOf: data) }
        catch {
            emitError("Codex 数据连接已断开，正在重连")
            resetConnection()
        }
    }

    private func emitQuotas(_ windows: [QuotaWindow]) {
        DispatchQueue.main.async { [weak self] in self?.onQuotas?(windows) }
    }

    private func emitThreadTitles(_ titles: [String: String]) {
        DispatchQueue.main.async { [weak self] in self?.onThreadTitles?(titles) }
    }

    private func emitError(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onError?(message) }
    }

}
