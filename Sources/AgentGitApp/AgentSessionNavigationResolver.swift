import AgentGitIntegrationShared
import Foundation

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

    static func available(_ url: URL) -> Self {
        Self(
            target: AgentSessionNavigationTarget(url: url),
            errorDescription: nil
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
    private static let nativeSessionIDCharacters = CharacterSet.alphanumerics.union(
        CharacterSet(charactersIn: "-_.")
    )

    let claudeSessionsRoot: URL

    init(claudeSessionsRoot: URL = Self.defaultClaudeSessionsRoot) {
        self.claudeSessionsRoot = claudeSessionsRoot.standardizedFileURL
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

        var resolutions: [AgentAssociation.ID: AgentSessionNavigationResolution] = [:]
        resolutions.reserveCapacity(associations.count)
        for association in associations {
            guard !Task.isCancelled else {
                return [:]
            }
            resolutions[association.id] = switch association.provider {
            case .codex:
                resolveCodex(association)
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
        _ association: AgentAssociation
    ) -> AgentSessionNavigationResolution {
        guard let sessionID = normalizedUUID(association.sessionID),
              let encodedID = sessionID.addingPercentEncoding(
                  withAllowedCharacters: .urlPathAllowed
              ),
              let url = URL(string: "codex://threads/\(encodedID)") else {
            return .unavailable("The Codex session ID is invalid.")
        }
        return .available(url)
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
        return .available(url)
    }

    private func loadClaudeDesktopSessionRecords(
        matching requestedSessionIDs: Set<String>
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
}

private struct ClaudeDesktopSessionRecord: Decodable, Sendable {
    let sessionID: String
    let cliSessionID: String
    let title: String?
    let isArchived: Bool?
    let completedTurns: Int64?
    let lastActivityAt: Int64?
    let createdAt: Int64?

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case cliSessionID = "cliSessionId"
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
