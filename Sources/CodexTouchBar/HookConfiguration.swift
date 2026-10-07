import Darwin
import Foundation

enum HookConfiguration {
    static let beginMarker = "# >>> CodexTouchBar status connection >>>"
    static let endMarker = "# <<< CodexTouchBar status connection <<<"
    static let events = [
        "SessionStart",
        "SessionEnd",
        "UserPromptSubmit",
        "PreToolUse",
        "PermissionRequest",
        "PostToolUse",
        "PostCompact",
        "SubagentStop",
        "Stop",
    ]

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/config.toml", isDirectory: false)
    }

    static func isInstalled() -> Bool {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return false }
        return text.contains(beginMarker) && text.contains(endMarker)
    }

    static func install(executablePath: String) throws {
        let existing = try readConfig()
        let withoutOwnedBlock = try removingOwnedBlock(from: existing)
        let command = "\(shellQuote(executablePath)) --hook"
        let block = try makeBlock(command: command)
        var next = withoutOwnedBlock.trimmingCharacters(in: .whitespacesAndNewlines)
        if !next.isEmpty { next += "\n\n" }
        next += block + "\n"
        try atomicWrite(next)
    }

    static func uninstall() throws {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return }
        let existing = try readConfig()
        let next = try removingOwnedBlock(from: existing)
        guard next != existing else { return }
        try atomicWrite(next)
    }

    static func removingOwnedBlock(from text: String) throws -> String {
        let beginRanges = text.ranges(of: beginMarker)
        let endRanges = text.ranges(of: endMarker)
        if beginRanges.isEmpty && endRanges.isEmpty { return text }
        guard beginRanges.count == 1, endRanges.count == 1 else {
            throw ConfigurationError.malformedOwnedBlock
        }
        guard let begin = beginRanges.first, let end = endRanges.first, begin.lowerBound < end.lowerBound else {
            throw ConfigurationError.malformedOwnedBlock
        }

        var upper = end.upperBound
        if upper < text.endIndex, text[upper] == "\n" { upper = text.index(after: upper) }
        var result = text
        result.removeSubrange(begin.lowerBound..<upper)
        while result.hasSuffix("\n\n\n") { result.removeLast() }
        return result
    }

    private static func makeBlock(command: String) throws -> String {
        let commandLiteral = try jsonStringLiteral(command)
        let statusLiteral = try jsonStringLiteral("Glance 正在同步状态")
        var lines = [beginMarker]
        for event in events {
            lines += [
                "[[hooks.\(event)]]",
                "[[hooks.\(event).hooks]]",
                "type = \"command\"",
                "command = \(commandLiteral)",
                "timeout = 2",
                "async = \(event == "SessionEnd" ? "false" : "true")",
                "statusMessage = \(statusLiteral)",
                "",
            ]
        }
        if lines.last?.isEmpty == true { lines.removeLast() }
        lines.append(endMarker)
        return lines.joined(separator: "\n")
    }

    private static func readConfig() throws -> String {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return "" }
        var info = stat()
        guard lstat(configURL.path, &info) == 0 else { throw ConfigurationError.unreadable }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else {
            throw ConfigurationError.unsafeFileType
        }
        return try String(contentsOf: configURL, encoding: .utf8)
    }

    private static func atomicWrite(_ text: String) throws {
        let directory = configURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = Data(text.utf8)
        let temporaryURL = directory.appendingPathComponent(".config.codextouchbar.\(UUID().uuidString).tmp")
        let fd = open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw ConfigurationError.writeFailed(errno) }
        var shouldRemove = true
        defer {
            Darwin.close(fd)
            if shouldRemove { try? FileManager.default.removeItem(at: temporaryURL) }
        }
        let result = data.withUnsafeBytes { bytes -> Int in
            guard let base = bytes.baseAddress else { return 0 }
            return Darwin.write(fd, base, bytes.count)
        }
        guard result == data.count, fsync(fd) == 0 else { throw ConfigurationError.writeFailed(errno) }
        guard rename(temporaryURL.path, configURL.path) == 0 else { throw ConfigurationError.writeFailed(errno) }
        shouldRemove = false
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }

    private static func jsonStringLiteral(_ value: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    enum ConfigurationError: LocalizedError {
        case unreadable
        case unsafeFileType
        case malformedOwnedBlock
        case writeFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .unreadable: return "无法读取 Codex config.toml"
            case .unsafeFileType: return "config.toml 不是安全的普通文件，已拒绝修改"
            case .malformedOwnedBlock: return "发现不完整的 CodexTouchBar 配置标记，未做任何修改"
            case .writeFailed: return "无法安全写入 config.toml"
            }
        }
    }
}

private extension String {
    func ranges(of needle: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var search = startIndex..<endIndex
        while let range = range(of: needle, range: search) {
            result.append(range)
            search = range.upperBound..<endIndex
        }
        return result
    }
}
