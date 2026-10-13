import Foundation

/// 串行写入本机日志，避免 Git 读取和界面刷新等待磁盘。
public final class AgentGitDiagnostics: @unchecked Sendable {
    public static let shared = AgentGitDiagnostics()
    @TaskLocal public static var operationID: String?

    public let directoryURL: URL
    public var logURL: URL { directoryURL.appendingPathComponent("agentgit.jsonl") }

    private let queue = DispatchQueue(label: "com.sigma.agentgit.diagnostics", qos: .utility)
    private let maximumFileBytes: Int
    private let backupCount: Int
    private var handle: FileHandle?
    private var fileBytes = 0
    private var reportedWriteFailure = false

    public init(
        directoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/AgentGit", isDirectory: true),
        maximumFileBytes: Int = 5 * 1_024 * 1_024,
        backupCount: Int = 3
    ) {
        self.directoryURL = directoryURL
        self.maximumFileBytes = max(1_024, maximumFileBytes)
        self.backupCount = max(1, backupCount)
    }

    deinit { try? handle?.close() }

    public func record(
        _ event: String, level: String = "info", fields: [String: String] = [:]
    ) {
        var boundedFields: [String: String] = [:]
        for (key, value) in fields {
            // Git 参数已经逐项遮盖；其他字段在截断前遮盖，避免切掉 URL 的凭据边界。
            let redacted = key == "arguments" ? value : Self.redact(value)
            boundedFields[key] = Self.prefix(redacted, byteCount: 128 * 1_024)
            if redacted.utf8.count > 128 * 1_024 {
                boundedFields["\(key)OriginalBytes"] = String(value.utf8.count)
                boundedFields["\(key)LogTruncated"] = "true"
            }
        }
        let entry = Entry(
            timestamp: Date(), processID: ProcessInfo.processInfo.processIdentifier,
            operationID: Self.operationID, event: event, level: level, fields: boundedFields
        )
        queue.async { [self] in
            do {
                var data = try entry.encoded(maximumBytes: min(maximumFileBytes - 1, 256 * 1_024))
                data.append(0x0a)
                try openIfNeeded()
                if fileBytes > 0 && fileBytes + data.count > maximumFileBytes {
                    try rotate()
                    try openIfNeeded()
                }
                try handle?.write(contentsOf: data)
                fileBytes += data.count
                reportedWriteFailure = false
            } catch {
                try? handle?.close()
                handle = nil
                if !reportedWriteFailure {
                    NSLog("AgentGit could not write diagnostic log: %@", String(describing: error))
                    reportedWriteFailure = true
                }
            }
        }
    }

    public func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                try? handle?.synchronize()
                continuation.resume()
            }
        }
    }

    private func openIfNeeded() throws {
        guard handle == nil else { return }
        let manager = FileManager.default
        try manager.createDirectory(
            at: directoryURL, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        if !manager.fileExists(atPath: logURL.path) {
            guard manager.createFile(
                atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600]
            ) else { throw CocoaError(.fileWriteUnknown) }
        }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
        let opened = try FileHandle(forWritingTo: logURL)
        do {
            fileBytes = Int(clamping: try opened.seekToEnd())
            handle = opened
        } catch {
            try? opened.close()
            throw error
        }
    }

    private func rotate() throws {
        try handle?.close()
        handle = nil
        let manager = FileManager.default
        for index in stride(from: backupCount, through: 1, by: -1) {
            let destination = directoryURL.appendingPathComponent("agentgit.\(index).jsonl")
            let source = index == 1 ? logURL
                : directoryURL.appendingPathComponent("agentgit.\(index - 1).jsonl")
            if manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }
            if manager.fileExists(atPath: source.path) {
                try manager.moveItem(at: source, to: destination)
            }
        }
        fileBytes = 0
    }

    private struct Entry: Encodable, Sendable {
        let timestamp: Date
        let processID: Int32
        let operationID: String?
        let event: String
        let level: String
        let fields: [String: String]

        func encoded(maximumBytes: Int) throws -> Data {
            var redactedFields = fields
            var loggedEvent = event
            var loggedLevel = level
            var loggedOperationID = operationID
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            while true {
                let entry = Entry(
                    timestamp: timestamp, processID: processID, operationID: loggedOperationID,
                    event: loggedEvent, level: loggedLevel, fields: redactedFields
                )
                let data = try encoder.encode(entry)
                guard data.count > maximumBytes else { return data }
                if let largest = redactedFields.filter({ $0.key != "recordTruncated" })
                    .max(by: { $0.value.utf8.count < $1.value.utf8.count }) {
                    if largest.value.utf8.count > 32 {
                        redactedFields[largest.key] = AgentGitDiagnostics.prefix(
                            largest.value, byteCount: largest.value.utf8.count / 2
                        )
                    } else {
                        redactedFields[largest.key] = nil
                    }
                } else if loggedEvent.utf8.count > 8 {
                    loggedEvent = AgentGitDiagnostics.prefix(loggedEvent, byteCount: loggedEvent.utf8.count / 2)
                } else if let id = loggedOperationID, id.utf8.count > 8 {
                    loggedOperationID = AgentGitDiagnostics.prefix(id, byteCount: id.utf8.count / 2)
                } else if loggedLevel.utf8.count > 8 {
                    loggedLevel = AgentGitDiagnostics.prefix(loggedLevel, byteCount: loggedLevel.utf8.count / 2)
                } else {
                    throw CocoaError(.fileWriteOutOfSpace)
                }
                redactedFields["recordTruncated"] = "true"
            }
        }
    }

    private static func prefix(_ value: String, byteCount: Int) -> String {
        String(decoding: value.utf8.prefix(byteCount), as: UTF8.self)
    }

    fileprivate static func redact(_ value: String) -> String {
        var result = value.replacingOccurrences(
            of: #"(https?://)[^/\s@]+@"#, with: "$1[redacted]@",
            options: .regularExpression
        )
        // stderr 本身也可能已被命令输出预算截断，保守遮盖未写完的 URL 凭据。
        result = result.replacingOccurrences(
            of: #"(https?://)[^/\s@]*:[^/\s@]*(?=\s|$)"#,
            with: "$1[redacted]", options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?im)((?:authorization|(?:http[^\s=]*\.)?extraheader)[=:]\s*)[^\r\n]+"#,
            with: "$1[redacted]", options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?i)((?:authorization|password|passwd|access_token|token|secret|extraheader)[=:]\s*)[^\s",]+"#,
            with: "$1[redacted]", options: .regularExpression
        )
        return result
    }
}

final class GitCommandDiagnosticTrace {
    private let diagnostics: AgentGitDiagnostics
    private let startedAt = ProcessInfo.processInfo.systemUptime
    var fields: [String: String]
    private var level = "info"

    init(
        diagnostics: AgentGitDiagnostics, executable: URL, arguments: [String],
        workingDirectory: URL, timeout: Duration?, maximumOutputBytes: Int?,
        maximumErrorBytes: Int?, writesOutputFile: Bool
    ) {
        self.diagnostics = diagnostics
        let loggedArguments = Array(arguments.prefix(128)).map(AgentGitDiagnostics.redact)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let data = try? encoder.encode(loggedArguments)
        fields = [
            "commandID": UUID().uuidString, "executable": executable.path,
            "workingDirectory": workingDirectory.path,
            "arguments": String(decoding: (data ?? Data()).prefix(32 * 1_024), as: UTF8.self),
            "argumentCount": String(arguments.count),
            "argumentBytes": String(data?.count ?? 0),
            "argumentsTruncated": String(loggedArguments.count != arguments.count || (data?.count ?? 0) > 32 * 1_024),
            "timeout": timeout.map(String.init(describing:)) ?? "none",
            "maximumOutputBytes": maximumOutputBytes.map(String.init) ?? "unlimited",
            "maximumErrorBytes": maximumErrorBytes.map(String.init) ?? "unlimited",
            "outputFile": String(writesOutputFile),
            "automaticMaintenance": "disabled"
        ]
        diagnostics.record("git.start", fields: fields)
    }

    func fail(_ error: any Error) {
        fields["error"] = String(describing: error)
        level = "error"
        switch error {
        case let failure as GitCommandFailure:
            fields["status"] = "failed"
            fields["exitCode"] = String(failure.exitCode)
            fields["error"] = "Git command failed with exit code \(failure.exitCode)"
            fields["stderr"] = failure.stderr
        case is GitCommandTimeoutError:
            fields["status"] = "timed_out"
        case is CancellationError:
            fields["status"] = "cancelled"
            level = "info"
        case let limit as GitCommandOutputLimitError:
            fields["status"] = limit.limit == 0 ? "output_present" : "output_limit"
            if limit.limit == 0 { level = "info" }
        default:
            fields["status"] = "execution_error"
        }
    }

    func finish() {
        fields["durationMs"] = String(
            format: "%.3f", (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
        )
        diagnostics.record("git.finish", level: level, fields: fields)
    }
}
