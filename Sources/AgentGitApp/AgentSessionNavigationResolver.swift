import AgentGitIntegrationShared
import Foundation
import SQLite3

struct AgentSessionNavigationTarget: Equatable, Sendable {
    let url: URL
}

enum AgentSessionNavigationAvailability: Equatable, Sendable {
    case resolving
    case available
    case unavailable(String)

    var sortRank: Int {
        switch self {
        case .available: 0
        case .resolving: 1
        case .unavailable: 2
        }
    }
}

struct AgentSessionNavigationResolution: Equatable, Sendable {
    let target: AgentSessionNavigationTarget?
    let errorDescription: String?
    /// 宿主当前显示的会话标题；关联里没存标题时用它显示。
    var title: String? = nil

    static func available(_ url: URL, title: String? = nil) -> Self {
        Self(
            target: AgentSessionNavigationTarget(url: url),
            errorDescription: nil,
            title: title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
    }

    static func unavailable(_ description: String) -> Self {
        Self(target: nil, errorDescription: description)
    }

    var availability: AgentSessionNavigationAvailability {
        if target != nil {
            return .available
        }
        return .unavailable(errorDescription ?? "This agent session cannot be opened.")
    }
}

struct AgentSessionNavigationResolver: Sendable {
    private static let maximumIndexFileSize = 2_000_000
    private static let maximumCodexIndexFileSize = 32_000_000
    private static let nativeSessionIDCharacters = CharacterSet.alphanumerics.union(
        CharacterSet(charactersIn: "-_.")
    )

    let claudeSessionsRoot: URL
    let codexHome: URL

    init(
        claudeSessionsRoot: URL = Self.defaultClaudeSessionsRoot,
        codexHome: URL = Self.defaultCodexHome
    ) {
        self.claudeSessionsRoot = claudeSessionsRoot.standardizedFileURL
        self.codexHome = codexHome.standardizedFileURL
    }

    /// 宿主自己建的 worktree 不经过 agent shell，hook 拿不到会话；按宿主元数据里记下的精确路径
    /// 找回所属会话：Claude Desktop 会话索引的 `worktreePath`，Codex App 放在
    /// `~/.codex/worktrees/` 下的 worktree 对应最早以它为 `cwd` 的线程。会话创建时间和
    /// worktree 的 git 管理目录创建时间要在一小时内，之后才在已有 worktree 里启动的会话不算。
    func discoverCreators(worktreePaths: Set<String>) -> [String: AgentWorktreeCreator] {
        var candidates: [AgentWorktreeCreator] = []
        for record in (try? loadClaudeDesktopSessionRecords(matching: nil)) ?? [] {
            guard let path = record.worktreePath.map({
                      URL(fileURLWithPath: $0).standardizedFileURL.path
                  }),
                  worktreePaths.contains(path),
                  let sessionID = normalizedUUID(record.cliSessionID),
                  let createdAt = record.createdAt else {
                continue
            }
            candidates.append(AgentWorktreeCreator(
                worktreePath: path,
                provider: .claude,
                sessionID: sessionID,
                hostSessionID: record.sessionID,
                title: record.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                createdAt: Date(timeIntervalSince1970: Double(createdAt) / 1000),
                source: "claude-desktop"
            ))
        }
        let codexWorktreesPrefix = codexHome.appendingPathComponent("worktrees").path + "/"
        let codexPaths = worktreePaths.filter { $0.hasPrefix(codexWorktreesPrefix) }
        let codexThreads = loadCodexWorktreeThreads(paths: codexPaths)
        candidates += codexThreads
        candidates += loadCodexCreateWorktreeThreads(
            paths: codexPaths.subtracting(codexThreads.map(\.worktreePath))
        )

        var creators: [String: AgentWorktreeCreator] = [:]
        for candidate in candidates.sorted(by: { $0.createdAt < $1.createdAt }) {
            guard creators[candidate.worktreePath] == nil,
                  let gitDirectoryCreatedAt = AgentWorktreeCreatorStore.gitDirectoryCreationDate(
                      worktreeRoot: URL(fileURLWithPath: candidate.worktreePath, isDirectory: true)
                  ),
                  abs(candidate.createdAt.timeIntervalSince(gitDirectoryCreatedAt))
                      <= AgentWorktreeCreatorStore.recreationTolerance else {
                continue
            }
            creators[candidate.worktreePath] = candidate
        }
        return creators
    }

    func resolve(
        _ associations: [AgentAssociation]
    ) -> [AgentAssociation.ID: AgentSessionNavigationResolution] {
        guard !Task.isCancelled else {
            return [:]
        }
        let requestedClaudeSessionIDs = Set<String>(
            associations.compactMap { association in
                guard association.provider == .claude else {
                    return nil
                }
                return normalizedUUID(association.sessionID)
            }
        )
        let claudeRecords: [ClaudeDesktopSessionRecord]
        let claudeIndexError: String?
        if !requestedClaudeSessionIDs.isEmpty {
            do {
                claudeRecords = try loadClaudeDesktopSessionRecords(
                    matching: requestedClaudeSessionIDs
                )
                claudeIndexError = nil
            } catch is CancellationError {
                return [:]
            } catch {
                claudeRecords = []
                claudeIndexError = String(describing: error)
            }
        } else {
            claudeRecords = []
            claudeIndexError = nil
        }

        let codexTitles = associations.contains { $0.provider == .codex }
            ? loadCodexThreadTitles()
            : [:]

        var resolutions: [AgentAssociation.ID: AgentSessionNavigationResolution] = [:]
        resolutions.reserveCapacity(associations.count)
        for association in associations {
            guard !Task.isCancelled else {
                return [:]
            }
            resolutions[association.id] = switch association.provider {
            case .codex:
                resolveCodex(association, titles: codexTitles)
            case .claude:
                resolveClaude(
                    association,
                    records: claudeRecords,
                    indexError: claudeIndexError
                )
            }
        }
        return resolutions
    }

    private func resolveCodex(
        _ association: AgentAssociation,
        titles: [String: String]
    ) -> AgentSessionNavigationResolution {
        guard let sessionID = normalizedUUID(association.sessionID),
              let encodedID = sessionID.addingPercentEncoding(
                  withAllowedCharacters: .urlPathAllowed
              ),
              let url = URL(string: "codex://threads/\(encodedID)") else {
            return .unavailable("The Codex session ID is invalid.")
        }
        return .available(url, title: titles[sessionID])
    }

    private func loadCodexWorktreeThreads(paths: Set<String>) -> [AgentWorktreeCreator] {
        // 表结构随版本迁移，文件名带版本号；取最新的 state_<n>.sqlite。
        guard let databaseURL = (try? FileManager.default.contentsOfDirectory(
                  at: codexHome,
                  includingPropertiesForKeys: nil
              ))?.filter({
                  $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite"
              }).max(by: {
                  $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
              }) else {
            return []
        }
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard !paths.isEmpty,
              sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return []
        }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, """
            SELECT id, name, COALESCE(created_at_ms, created_at * 1000) FROM threads
            WHERE cwd = ?1 ORDER BY 3 LIMIT 1
            """, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var creators: [AgentWorktreeCreator] = []
        for path in paths {
            sqlite3_reset(statement)
            sqlite3_bind_text(statement, 1, path, -1, transient)
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let id = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
                  let sessionID = normalizedUUID(id) else {
                continue
            }
            creators.append(AgentWorktreeCreator(
                worktreePath: path,
                provider: .codex,
                sessionID: sessionID,
                title: sqlite3_column_text(statement, 1).map { String(cString: $0) }?.nilIfEmpty,
                createdAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 2)) / 1000),
                source: "codex-app"
            ))
        }
        return creators
    }

    /// Codex 的 `create_worktree` 工具由 Codex App 自己建 worktree：git 拿不到线程 ID，线程的 cwd
    /// 也还是原目录，唯一精确的记录是该线程会话日志里这次调用的返回（`worktreeGitRoot` 等于该路径）。
    /// 只读 worktree 创建之后仍在写入的会话日志，只认同一行里同时出现 `worktreeGitRoot` 和该路径。
    /// 每次项目刷新都会补查，日志总量很大，只查一天内建的 worktree。
    private func loadCodexCreateWorktreeThreads(paths: Set<String>) -> [AgentWorktreeCreator] {
        let recentCutoff = Date().addingTimeInterval(-86_400)
        var remaining: [String: Date] = [:]
        for path in paths {
            if let createdAt = AgentWorktreeCreatorStore.gitDirectoryCreationDate(
                worktreeRoot: URL(fileURLWithPath: path, isDirectory: true)
            ), createdAt >= recentCutoff {
                remaining[path] = createdAt
            }
        }
        guard let earliest = remaining.values.min(),
              let enumerator = FileManager.default.enumerator(
                  at: codexHome.appendingPathComponent("sessions", isDirectory: true),
                  includingPropertiesForKeys: [.contentModificationDateKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return []
        }
        var creators: [AgentWorktreeCreator] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard !remaining.isEmpty, !Task.isCancelled else {
                break
            }
            // 文件名是 rollout-<时间>-<线程 ID>.jsonl。
            guard let modifiedAt = try? url.resourceValues(
                      forKeys: [.contentModificationDateKey]
                  ).contentModificationDate,
                  modifiedAt >= earliest,
                  let sessionID = normalizedUUID(
                      String(url.deletingPathExtension().lastPathComponent.suffix(36))
                  ),
                  let data = try? Data(contentsOf: url, options: .alwaysMapped) else {
                continue
            }
            for (path, createdAt) in remaining
            where modifiedAt >= createdAt && Self.containsCreateWorktreeResult(data, path: path) {
                creators.append(AgentWorktreeCreator(
                    worktreePath: path,
                    provider: .codex,
                    sessionID: sessionID,
                    createdAt: createdAt,
                    source: "codex-app"
                ))
                remaining[path] = nil
            }
        }
        return creators
    }

    private static func containsCreateWorktreeResult(_ data: Data, path: String) -> Bool {
        let needle = Data(path.utf8)
        let marker = Data("worktreeGitRoot".utf8)
        let newline = Data([0x0A])
        var searchStart = data.startIndex
        while let match = data.range(of: needle, in: searchStart..<data.endIndex) {
            let lineStart = data.range(
                of: newline,
                options: .backwards,
                in: data.startIndex..<match.lowerBound
            )?.upperBound ?? data.startIndex
            let lineEnd = data.range(of: newline, in: match.upperBound..<data.endIndex)?.lowerBound
                ?? data.endIndex
            // 路径后面必须是 JSON 字符串的结尾（引号或转义引号），排除同名前缀的其它目录。
            let next = match.upperBound < data.endIndex ? data[match.upperBound] : 0
            if (next == UInt8(ascii: "\"") || next == UInt8(ascii: "\\")),
               data.range(of: marker, in: lineStart..<lineEnd) != nil {
                return true
            }
            searchStart = lineEnd
        }
        return false
    }

    /// session_index.jsonl 每行 `{"id","thread_name","updated_at"}`，改名会追加新行，后出现的为准。
    private func loadCodexThreadTitles() -> [String: String] {
        guard let data = try? Data(
                  contentsOf: codexHome.appendingPathComponent("session_index.jsonl"),
                  options: .mappedIfSafe
              ),
              data.count <= Self.maximumCodexIndexFileSize else {
            return [:]
        }
        let decoder = JSONDecoder()
        var titles: [String: String] = [:]
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let entry = try? decoder.decode(CodexSessionIndexEntry.self, from: line),
                  let sessionID = normalizedUUID(entry.id) else {
                continue
            }
            titles[sessionID] = entry.threadName
        }
        return titles
    }

    private func resolveClaude(
        _ association: AgentAssociation,
        records: [ClaudeDesktopSessionRecord],
        indexError: String?
    ) -> AgentSessionNavigationResolution {
        guard let sessionID = normalizedUUID(association.sessionID) else {
            return .unavailable("The Claude session ID is invalid.")
        }
        if let indexError {
            return .unavailable(indexError)
        }
        let matches = records.filter { $0.cliSessionID == sessionID }
        guard let selected = matches.max(by: {
            isClaudeRecord($1, preferredOver: $0, sessionID: sessionID)
        }) else {
            return .unavailable(
                "Claude Desktop no longer has an exact mapping for this session."
            )
        }
        guard isSafeNativeSessionID(selected.sessionID),
              let encodedID = selected.sessionID.addingPercentEncoding(
                  withAllowedCharacters: .urlPathAllowed
              ),
              let url = URL(
                  string: "claude://claude.ai/claude-code-desktop/\(encodedID)"
              ) else {
            return .unavailable("Claude Desktop returned an invalid session mapping.")
        }
        return .available(url, title: selected.title)
    }

    /// `requestedSessionIDs` 为 nil 时返回全部记录。
    private func loadClaudeDesktopSessionRecords(
        matching requestedSessionIDs: Set<String>?
    ) throws -> [ClaudeDesktopSessionRecord] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: claudeSessionsRoot.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw AgentSessionNavigationResolverError.claudeIndexUnavailable
        }
        guard let enumerator = FileManager.default.enumerator(
            at: claudeSessionsRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw AgentSessionNavigationResolverError.claudeIndexUnavailable
        }

        let decoder = JSONDecoder()
        var records: [ClaudeDesktopSessionRecord] = []
        for case let url as URL in enumerator where url.pathExtension == "json" {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true,
                  let fileSize = values.fileSize,
                  fileSize <= Self.maximumIndexFileSize else {
                continue
            }
            guard let record = try? decoder.decode(
                ClaudeDesktopSessionRecord.self,
                from: Data(contentsOf: url)
            ) else {
                continue
            }
            try Task.checkCancellation()
            guard let requestedSessionIDs else {
                records.append(record)
                continue
            }
            if let sessionID = normalizedUUID(record.cliSessionID),
               requestedSessionIDs.contains(sessionID) {
                records.append(record)
            }
        }
        return records
    }

    private func isClaudeRecord(
        _ candidate: ClaudeDesktopSessionRecord,
        preferredOver current: ClaudeDesktopSessionRecord,
        sessionID: String
    ) -> Bool {
        let candidatePreference = claudePreference(candidate, sessionID: sessionID)
        let currentPreference = claudePreference(current, sessionID: sessionID)
        for index in candidatePreference.indices {
            if candidatePreference[index] != currentPreference[index] {
                return candidatePreference[index] > currentPreference[index]
            }
        }
        return candidate.sessionID < current.sessionID
    }

    private func claudePreference(
        _ record: ClaudeDesktopSessionRecord,
        sessionID: String
    ) -> [Int64] {
        [
            record.isArchived == true ? 0 : 1,
            record.sessionID == "local_\(sessionID)" ? 0 : 1,
            record.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? 1
                : 0,
            record.completedTurns ?? 0,
            record.lastActivityAt ?? 0,
            -(record.createdAt ?? Int64.max)
        ]
    }

    private func normalizedUUID(_ value: String) -> String? {
        UUID(uuidString: value)?.uuidString.lowercased()
    }

    private func isSafeNativeSessionID(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 256
            && value.rangeOfCharacter(
                from: Self.nativeSessionIDCharacters.inverted
            ) == nil
    }

    private static var defaultClaudeSessionsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("claude-code-sessions", isDirectory: true)
    }

    private static var defaultCodexHome: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }
}

private struct CodexSessionIndexEntry: Decodable {
    let id: String
    let threadName: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case threadName = "thread_name"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private struct ClaudeDesktopSessionRecord: Decodable, Sendable {
    let sessionID: String
    let cliSessionID: String
    let title: String?
    let isArchived: Bool?
    let completedTurns: Int64?
    let lastActivityAt: Int64?
    let createdAt: Int64?
    let worktreePath: String?

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case cliSessionID = "cliSessionId"
        case worktreePath
        case title
        case isArchived
        case completedTurns
        case lastActivityAt
        case createdAt
    }
}

private enum AgentSessionNavigationResolverError: LocalizedError {
    case claudeIndexUnavailable

    var errorDescription: String? {
        switch self {
        case .claudeIndexUnavailable:
            "Claude Desktop session data is unavailable. Open Claude Desktop and try again."
        }
    }
}
