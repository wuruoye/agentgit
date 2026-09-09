import CryptoKit
import Darwin
import Foundation

/// Consumes host events without evaluating command text. Failures request bounded LLM diagnosis.
/// PreToolUse saves a bounded baseline; PostToolUse links only roots that changed.
public struct AgentHookRegistration {
    /// PreToolUse 会阻塞宿主的工具调用，预算按「两档探测各一秒」留；
    /// PostToolUse 是异步的，可以给单档更宽的时间把基线复算完。
    private static let preToolUseDeadline: TimeInterval = 4.5
    private static let preToolUseStatusBudget: TimeInterval = 1.0
    private static let postToolUseDeadline: TimeInterval = 6.0
    private static let postToolUseStatusBudget: TimeInterval = 3.0
    private static let scopeCacheLifetime: TimeInterval = 24 * 60 * 60

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
                let deadline = ProcessInfo.processInfo.systemUptime + Self.preToolUseDeadline
                let snapshots = try targets.map { target in
                    let probe = try fingerprint(
                        target, scope: nil, deadline: deadline,
                        statusBudget: Self.preToolUseStatusBudget, now: now
                    )
                    return Baseline(target: target, fingerprint: probe.value, scope: probe.scope)
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
            let deadline = ProcessInfo.processInfo.systemUptime + Self.postToolUseDeadline
            var changed = false
            let service = AgentSkillRegistrationService(
                associationStore: AgentAssociationStore(storeURL: rootURL.appendingPathComponent("associations.json")),
                auditStore: auditStore
            )
            for baseline in baselines {
                let probe = try fingerprint(
                    baseline.target, scope: baseline.scope ?? .untrackedAll,
                    deadline: deadline, statusBudget: Self.postToolUseStatusBudget, now: now
                )
                guard probe.value != baseline.fingerprint else { continue }
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

    private func fingerprint(
        _ target: Target,
        scope requestedScope: ProbeScope?,
        deadline: TimeInterval,
        statusBudget: TimeInterval,
        now: Date
    ) throws -> (value: String, scope: ProbeScope) {
        if let files = target.files {
            var data = Data()
            for path in files {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw HookError.limitExceeded }
                data.append(Data(path.utf8))
                data.append(try fileFingerprint(path))
            }
            return (digest(data), .untrackedAll)
        }
        let worktree = URL(fileURLWithPath: target.worktree, isDirectory: true)
        // 超大 worktree 的全量 status 跑不进一次 Hook 的预算。逐级缩小探测范围，
        // 让这类仓库拿到一个能复算的基线，而不是每次调用都以超时失败告终。
        // 从上次记下的档位起步，否则每次 PreToolUse 都要把超时的档位重跑一遍。
        let scopes: [ProbeScope]
        if let requestedScope {
            scopes = [requestedScope]
        } else {
            let cached = cachedScope(target.worktree, now: now) ?? .untrackedAll
            scopes = Array(ProbeScope.allCases.drop { $0 != cached })
        }
        for scope in scopes {
            guard let data = try statusFingerprintData(
                worktree, scope: scope, deadline: deadline, statusBudget: statusBudget
            ) else {
                continue
            }
            if requestedScope == nil {
                storeScope(scope, worktree: target.worktree, now: now)
            }
            return (digest(data), scope)
        }
        throw HookError.limitExceeded
    }

    /// 记住每个 worktree 上次成功的探测档位，过期后重新从最大范围试一遍。
    private func cachedScope(_ worktree: String, now: Date) -> ProbeScope? {
        guard let entry = loadScopeCache()[worktree],
              now.timeIntervalSince(entry.updatedAt) < Self.scopeCacheLifetime,
              entry.updatedAt <= now else {
            return nil
        }
        return entry.scope
    }

    private func storeScope(_ scope: ProbeScope, worktree: String, now: Date) {
        var cache = loadScopeCache()
        if let entry = cache[worktree], entry.scope == scope,
           now.timeIntervalSince(entry.updatedAt) < Self.scopeCacheLifetime / 4 {
            return
        }
        cache[worktree] = ScopeCacheEntry(scope: scope, updatedAt: now)
        if cache.count > 64 {
            cache = Dictionary(
                uniqueKeysWithValues: cache.sorted { $0.value.updatedAt > $1.value.updatedAt }
                    .prefix(64).map { ($0.key, $0.value) }
            )
        }
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: scopeCacheURL, options: .atomic)
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: scopeCacheURL.path
        )
    }

    private func loadScopeCache() -> [String: ScopeCacheEntry] {
        guard let data = try? Data(contentsOf: scopeCacheURL), data.count <= 200_000,
              let cache = try? JSONDecoder().decode(
                  [String: ScopeCacheEntry].self, from: data
              ) else {
            return [:]
        }
        return cache
    }

    private var scopeCacheURL: URL {
        rootURL.appendingPathComponent("probe-scopes.json")
    }

    /// 返回 nil 表示这一档探测超出预算，可以降级重试；仓库真的读不了才抛错。
    private func statusFingerprintData(
        _ worktree: URL,
        scope: ProbeScope,
        deadline: TimeInterval,
        statusBudget: TimeInterval
    ) throws -> Data? {
        var data = Data("\(scope.rawValue)\u{0}".utf8)
        if let statusArguments = scope.statusArguments {
            guard let status = try gitStatus(
                worktree,
                statusArguments: statusArguments,
                deadline: deadline,
                statusBudget: statusBudget * scope.budgetScale
            ) else {
                return nil
            }
            data.append(status)
            let fields = status.split(separator: 0, omittingEmptySubsequences: true)
            guard fields.count <= 2_000 else { return nil }
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
                guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            }
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
        return data
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

    private func gitStatus(
        _ worktree: URL,
        statusArguments: [String],
        deadline: TimeInterval,
        statusBudget: TimeInterval
    ) throws -> Data? {
        let outputURL = rootURL.appendingPathComponent(".hook-status-\(UUID().uuidString)")
        guard fileManager.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw HookError.unreadableTarget
        }
        defer { try? fileManager.removeItem(at: outputURL) }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        // 沿用仓库自己的 fsmonitor / untrackedCache 配置：App 主刷新路径也这么跑，
        // 关掉它们会让配了 fsmonitor 的大仓库慢上数倍，正好把探测拖过预算。
        process.arguments = [
            "--no-optional-locks", "status", "--porcelain=v1", "-z"
        ] + statusArguments
        process.currentDirectoryURL = worktree
        // A hook's ambient Git variables must not redirect a probe into another repository.
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "GIT_OPTIONAL_LOCKS": "0", "LC_ALL": "C"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let probeDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + statusBudget)
        while process.isRunning {
            let size = (try? fileManager.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.intValue ?? 0
            if ProcessInfo.processInfo.systemUptime >= probeDeadline || size > 1_000_000 {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
                return nil
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        guard process.terminationStatus == 0 else { throw HookError.invalidRepository }
        let data = try Data(contentsOf: outputURL)
        guard data.count <= 1_000_000 else { return nil }
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
        let scope: ProbeScope?
    }

    private struct ScopeCacheEntry: Codable {
        let scope: ProbeScope
        let updatedAt: Date
    }

    /// 探测范围从大到小；PostToolUse 必须沿用基线记录的这一档，指纹才可比。
    private enum ProbeScope: String, Codable, CaseIterable {
        case untrackedAll
        case trackedOnly
        case trackedWithoutSubmodules
        case gitMetadata

        /// nil 表示这一档不跑 status，只看 .git 元数据。
        var statusArguments: [String]? {
            switch self {
            case .untrackedAll: ["--untracked-files=all"]
            case .trackedOnly: ["--untracked-files=no"]
            case .trackedWithoutSubmodules: ["--untracked-files=no", "--ignore-submodules=all"]
            case .gitMetadata: nil
            }
        }

        /// 各档开销差别很大，预算按倍数给，避免便宜的档被贵的档的超时拖垮。
        var budgetScale: Double {
            switch self {
            case .untrackedAll: 1.0
            case .trackedOnly: 1.5
            case .trackedWithoutSubmodules: 1.0
            case .gitMetadata: 0
            }
        }
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
