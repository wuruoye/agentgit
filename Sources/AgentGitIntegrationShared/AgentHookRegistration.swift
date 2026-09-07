import CryptoKit
import Darwin
import Foundation

/// Consumes host events without evaluating command text. Failures request bounded LLM diagnosis.
/// PreToolUse saves a bounded baseline; PostToolUse links only roots that changed.
public struct AgentHookRegistration {
    private let rootURL: URL
    private let provider: AgentProvider
    private let pluginVersion: String?
    private let fileManager = FileManager.default

    public init(rootURL: URL, provider: AgentProvider, pluginVersion: String? = nil) {
        self.rootURL = rootURL
        self.provider = provider
        self.pluginVersion = pluginVersion
    }

    @discardableResult
    public func handle(_ data: Data, now: Date = Date()) -> AgentHookFeedback? {
        var sessionID: String?
        var eventName: String?
        var diagnosticEvent: [String: Any] = [:]
        do {
            guard data.count <= 2_000_000,
                  let event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = event["hook_event_name"] as? String else {
                throw HookError.invalidEvent
            }
            eventName = name
            diagnosticEvent = event
            guard let session = event["session_id"] as? String,
                  !session.isEmpty, session.utf8.count <= 256 else {
                throw HookError.invalidEvent
            }
            sessionID = session
            if name == "SessionStart" {
                record(.succeeded, session, "Hook received; waiting for a repository change.", now)
                return nil
            }
            guard name == "PreToolUse" || name == "PostToolUse" || name == "PostToolUseFailure",
                  let callID = event["tool_use_id"] as? String,
                  !callID.isEmpty, callID.utf8.count <= 512 else {
                throw HookError.invalidEvent
            }
            let pendingRoot = rootURL.appendingPathComponent("hook-pending", isDirectory: true)
            let pendingURL = pendingRoot.appendingPathComponent(
                digest(Data("\(provider.rawValue)\u{0}\(session)\u{0}\(callID)".utf8)) + ".json"
            )
            if name == "PreToolUse" {
                let existing = try AgentAssociationStore(
                    storeURL: rootURL.appendingPathComponent("associations.json")
                ).list()
                let targets = try targets(event).filter { target in
                    !existing.contains {
                        $0.provider == provider && $0.sessionID == session && $0.worktreePath == target.worktree
                    }
                }
                guard !targets.isEmpty else { return nil }
                try fileManager.createDirectory(
                    at: pendingRoot, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try? fileManager.removeItem(at: pendingURL)
                try prune(pendingRoot, now: now)
                let deadline = ProcessInfo.processInfo.systemUptime + 1.5
                let snapshots = try targets.map { target in
                    Baseline(target: target, fingerprint: try fingerprint(target, deadline: deadline))
                }
                let pending = Pending(createdAt: now, baselines: snapshots)
                try JSONEncoder().encode(pending).write(to: pendingURL, options: .atomic)
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pendingURL.path)
                return nil
            }
            guard fileManager.fileExists(atPath: pendingURL.path) else {
                let candidates = try targets(event)
                let existing = try AgentAssociationStore(
                    storeURL: rootURL.appendingPathComponent("associations.json")
                ).list()
                if candidates.allSatisfy({ target in
                    existing.contains {
                        $0.provider == provider && $0.sessionID == session && $0.worktreePath == target.worktree
                    }
                }) { return nil }
                throw HookError.missingBaseline
            }
            defer { try? fileManager.removeItem(at: pendingURL) }
            let pending = try JSONDecoder().decode(Pending.self, from: Data(contentsOf: pendingURL))
            let existing = try AgentAssociationStore(
                storeURL: rootURL.appendingPathComponent("associations.json")
            ).list()
            let baselines = pending.baselines.filter { baseline in
                !existing.contains {
                    $0.provider == provider && $0.sessionID == session && $0.worktreePath == baseline.target.worktree
                }
            }
            guard !baselines.isEmpty else { return nil }
            guard now.timeIntervalSince(pending.createdAt) < 24 * 60 * 60 else {
                throw HookError.expiredBaseline
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 1.5
            var changed = false
            let service = AgentSkillRegistrationService(
                associationStore: AgentAssociationStore(storeURL: rootURL.appendingPathComponent("associations.json")),
                auditStore: auditStore
            )
            for baseline in baselines {
                guard try fingerprint(baseline.target, deadline: deadline) != baseline.fingerprint else { continue }
                // A nonzero shell exit can still have changed files. Use the observed state,
                // not the exit status, to decide whether this worktree needs an association.
                _ = try service.register(
                    provider: provider, sessionID: session,
                    candidateURL: URL(fileURLWithPath: baseline.target.worktree), now: now
                )
                changed = true
            }
            if changed { diagnostic.resolved(session: session) }
            record(
                changed ? .succeeded : .skipped, session,
                changed ? "Repository change observed; session linked." : "No repository change observed.", now
            )
        } catch {
            record(.failed, sessionID, "Automatic registration failed: \(error.localizedDescription)", now)
            return diagnostic.feedback(
                event: eventName, session: sessionID, message: error.localizedDescription,
                toolCallID: diagnosticEvent["tool_use_id"] as? String,
                toolName: diagnosticEvent["tool_name"] as? String,
                cwd: diagnosticEvent["cwd"] as? String,
                now: now
            )
        }
        return nil
    }

    private var diagnostic: AgentHookDiagnostic {
        AgentHookDiagnostic(rootURL: rootURL, provider: provider, pluginVersion: pluginVersion)
    }

    private var auditStore: AgentRegistrationAuditStore {
        AgentRegistrationAuditStore(storeURL: rootURL.appendingPathComponent("registration-events.json"))
    }

    private func record(_ outcome: AgentRegistrationOutcome, _ session: String?, _ message: String, _ now: Date) {
        _ = try? auditStore.record(
            AgentRegistrationEvent(
                provider: provider, action: .hook, outcome: outcome,
                sessionID: session, worktreePath: nil, message: message, createdAt: now,
                pluginVersion: pluginVersion
            ), minimumInterval: 60
        )
    }

    private func targets(_ event: [String: Any]) throws -> [Target] {
        guard let cwd = event["cwd"] as? String, cwd.hasPrefix("/"),
              let tool = event["tool_name"] as? String,
              let input = event["tool_input"] as? [String: Any] else {
            throw HookError.invalidEvent
        }
        let sessionDirectory = URL(fileURLWithPath: cwd, isDirectory: true)
        let executionDirectory = input["cwd"] as? String ?? input["workdir"] as? String
        let directory = executionDirectory.map { resolve($0, relativeTo: sessionDirectory) } ?? sessionDirectory
        var paths: [URL] = []
        let shell = tool == "Bash" || tool == "exec_command" || tool == "shell_command" || tool == "shell"
        if shell {
            guard let command = input["command"] as? String ?? input["cmd"] as? String else {
                throw HookError.unsupportedTool
            }
            paths = [directory]
            // Recognize literal directory operands without running a shell. Dynamic cd/-C
            // operands are rejected; cwd is never substituted for an unresolved target.
            let words = try literalWords(command.components(separatedBy: "<<")[0])
            var currentDirectory = directory
            var gitDirectory = directory
            for index in words.indices where index + 1 < words.count {
                if words[index] == "git" || words[index].hasSuffix("/git") {
                    gitDirectory = currentDirectory
                } else if words[index].hasPrefix("--git-dir") || words[index].hasPrefix("GIT_DIR=") {
                    throw HookError.dynamicDirectory
                } else if words[index] == "cd" {
                    let pathIndex = words[index + 1] == "--" ? index + 2 : index + 1
                    guard pathIndex < words.count, isLiteralPath(words[pathIndex]) else {
                        throw HookError.dynamicDirectory
                    }
                    currentDirectory = resolve(words[pathIndex], relativeTo: currentDirectory)
                    gitDirectory = currentDirectory
                    paths.append(currentDirectory)
                } else if words[index] == "-C" {
                    guard isLiteralPath(words[index + 1]) else { throw HookError.dynamicDirectory }
                    gitDirectory = resolve(words[index + 1], relativeTo: gitDirectory)
                    paths.append(gitDirectory)
                }
            }
        } else if tool == "apply_patch" {
            guard let patch = input["command"] as? String ?? input["patch"] as? String else {
                throw HookError.unsupportedTool
            }
            for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
                for prefix in ["*** Add File: ", "*** Update File: ", "*** Delete File: ", "*** Move to: "] {
                    if line.hasPrefix(prefix) {
                        paths.append(resolve(String(line.dropFirst(prefix.count)), relativeTo: directory))
                    }
                }
            }
        } else if ["Write", "Edit", "MultiEdit", "NotebookEdit"].contains(tool) {
            if let path = input["file_path"] as? String ?? input["notebook_path"] as? String {
                paths = [resolve(path, relativeTo: directory)]
            }
        } else {
            throw HookError.unsupportedTool
        }
        guard paths.count <= 256 else { throw HookError.limitExceeded }
        var grouped: [String: [String]] = [:]
        for path in paths {
            if let root = AgentWorktreeLocator.root(containing: path) {
                grouped[root.standardizedFileURL.path, default: []].append(path.standardizedFileURL.resolvingSymlinksInPath().path)
            }
        }
        guard grouped.count <= 4 else { throw HookError.limitExceeded }
        return grouped.keys.sorted().map {
            Target(worktree: $0, files: shell ? nil : Array(Set(grouped[$0]!)).sorted())
        }
    }

    private func fingerprint(_ target: Target, deadline: TimeInterval) throws -> String {
        if let files = target.files {
            var data = Data()
            for path in files {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw HookError.limitExceeded }
                data.append(Data(path.utf8))
                data.append(try fileFingerprint(path))
            }
            return digest(data)
        }
        let worktree = URL(fileURLWithPath: target.worktree, isDirectory: true)
        var data = try gitStatus(worktree, deadline: deadline)
        let fields = data.split(separator: 0, omittingEmptySubsequences: true)
        guard fields.count <= 2_000 else { throw HookError.limitExceeded }
        var index = 0
        while index < fields.count {
            let field = fields[index]
            guard field.count >= 4, field[field.startIndex + 2] == 32,
                  let path = String(data: field.dropFirst(3), encoding: .utf8) else {
                throw HookError.limitExceeded
            }
            data.append(try fileMetadata(worktree.appendingPathComponent(path).path))
            if field.prefix(2).contains(82) || field.prefix(2).contains(67) { index += 1 }
            index += 1
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw HookError.limitExceeded }
        }
        var gitDirectory = worktree.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: gitDirectory.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            let value = try String(contentsOf: gitDirectory, encoding: .utf8)
            guard value.hasPrefix("gitdir: ") else { throw HookError.invalidRepository }
            gitDirectory = resolve(String(value.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: worktree)
        }
        for path in ["HEAD", "index", "logs/HEAD"] {
            data.append(try fileMetadata(gitDirectory.appendingPathComponent(path).path))
        }
        return digest(data)
    }

    private func fileFingerprint(_ path: String) throws -> Data {
        var data = try fileMetadata(path)
        if let attributes = try? fileManager.attributesOfItem(atPath: path),
           attributes[.type] as? FileAttributeType == .typeRegular,
           (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 1_000_000 {
            data.append(Data(digest(try Data(contentsOf: URL(fileURLWithPath: path))).utf8))
        }
        return data
    }

    private func fileMetadata(_ path: String) throws -> Data {
        var info = stat()
        if lstat(path, &info) != 0 {
            if errno == ENOENT || errno == ENOTDIR { return Data("missing\u{0}".utf8) }
            throw HookError.unreadableTarget
        }
        return Data("\(info.st_mode):\(info.st_size):\(info.st_ino):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)\u{0}".utf8)
    }

    private func gitStatus(_ worktree: URL, deadline: TimeInterval) throws -> Data {
        let outputURL = rootURL.appendingPathComponent(".hook-status-\(UUID().uuidString)")
        guard fileManager.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw HookError.unreadableTarget
        }
        defer { try? fileManager.removeItem(at: outputURL) }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false", "status", "--porcelain=v1", "-z", "--untracked-files=all"]
        process.currentDirectoryURL = worktree
        // A hook's ambient Git variables must not redirect a probe into another repository.
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "GIT_OPTIONAL_LOCKS": "0", "LC_ALL": "C"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let probeDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + 0.5)
        while process.isRunning {
            let size = (try? fileManager.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.intValue ?? 0
            if ProcessInfo.processInfo.systemUptime >= probeDeadline || size > 1_000_000 {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
                throw HookError.limitExceeded
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        guard process.terminationStatus == 0 else { throw HookError.invalidRepository }
        let data = try Data(contentsOf: outputURL)
        guard data.count <= 1_000_000 else { throw HookError.limitExceeded }
        return data
    }

    private func prune(_ directory: URL, now: Date) throws {
        let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        for file in files {
            if let date = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               now.timeIntervalSince(date) > 24 * 60 * 60 {
                try? fileManager.removeItem(at: file)
            }
        }
        guard files.count < 1_024 else { throw HookError.limitExceeded }
    }

    private func resolve(_ path: String, relativeTo directory: URL) -> URL {
        (path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path))
            .standardizedFileURL.resolvingSymlinksInPath()
    }

    private func isLiteralPath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("-") && path.rangeOfCharacter(from: CharacterSet(charactersIn: "$`~*?{}()<>")) == nil
    }

    private func literalWords(_ command: String) throws -> [String] {
        var words: [String] = []
        var word = ""
        var quote: Character?
        var escaped = false
        for character in command {
            if escaped { word.append(character); escaped = false; continue }
            if character == "\\", quote != "'" { escaped = true; continue }
            if let currentQuote = quote {
                if character == currentQuote { quote = nil } else { word.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character.isWhitespace || ";|&".contains(character) {
                if !word.isEmpty { words.append(word); word = "" }
            } else { word.append(character) }
        }
        // Do not parse malformed shell text or heredoc bodies as directory operands.
        guard quote == nil, !escaped else { throw HookError.dynamicDirectory }
        if !word.isEmpty { words.append(word) }
        return words
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct Target: Codable {
        let worktree: String
        let files: [String]?
    }

    private struct Baseline: Codable {
        let target: Target
        let fingerprint: String
    }

    private struct Pending: Codable {
        let createdAt: Date
        let baselines: [Baseline]
    }

    private enum HookError: String, LocalizedError {
        case invalidEvent = "Host event is missing a stable session, call ID, or directory."
        case unsupportedTool = "This tool does not expose supported file targets."
        case dynamicDirectory = "Shell directory cannot be resolved literally; use an explicit tool working directory or manual registration."
        case limitExceeded = "Repository probe exceeded its time, size, or pending-call limit."
        case invalidRepository = "Git could not read the target worktree."
        case unreadableTarget = "Target metadata or local storage is unavailable."
        case missingBaseline = "No baseline for this tool call; check the matching PreToolUse event."
        case expiredBaseline = "The tool baseline expired; retry on the next change."
        var errorDescription: String? { rawValue }
    }
}
