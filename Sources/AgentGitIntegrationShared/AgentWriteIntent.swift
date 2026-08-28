import Foundation

public struct AgentHookEvent: Decodable, Sendable {
    public struct ToolInput: Decodable, Sendable {
        public let filePath: String?
        public let path: String?
        public let command: String?
        public let cmd: String?
        public let cwd: String?
        public let workdir: String?

        private enum CodingKeys: String, CodingKey {
            case filePath = "file_path"
            case path
            case command
            case cmd
            case cwd
            case workdir
        }
    }

    public let sessionID: String?
    public let cwd: String?
    public let workdir: String?
    public let toolName: String
    public let toolInput: ToolInput?

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case cwd
        case workdir
        case toolName = "tool_name"
        case toolInput = "tool_input"
    }
}

public struct AgentWriteIntent: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let provider: AgentProvider
    public let sessionID: String
    public let worktreePath: String
    public let toolName: String
    public let targetPath: String?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        provider: AgentProvider,
        sessionID: String,
        worktreePath: String,
        toolName: String,
        targetPath: String?,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.provider = provider
        self.sessionID = sessionID
        self.worktreePath = URL(
            fileURLWithPath: worktreePath
        ).standardizedFileURL.path
        self.toolName = toolName
        self.targetPath = targetPath.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }
        self.createdAt = createdAt
    }
}

public struct AgentWriteRegistrationResponse: Codable, Equatable, Sendable {
    public let token: UUID
    public let provider: AgentProvider
    public let sessionID: String
    public let worktreePath: String
    public let title: String
    public let summary: String
    public let preparedAt: Date

    public init(
        token: UUID,
        provider: AgentProvider,
        sessionID: String,
        worktreePath: String,
        title: String,
        summary: String,
        preparedAt: Date = Date()
    ) {
        self.token = token
        self.provider = provider
        self.sessionID = sessionID
        self.worktreePath = URL(
            fileURLWithPath: worktreePath
        ).standardizedFileURL.path
        self.title = title
        self.summary = summary
        self.preparedAt = preparedAt
    }
}

public enum AgentWriteGuardDecision: Equatable, Sendable {
    case allow
    case registrationRequired(AgentWriteIntent)
    case blocked(String)
}

public enum AgentWriteIntentStoreError: LocalizedError, Equatable, Sendable {
    case invalidToken
    case intentMissing
    case intentExpired

    public var errorDescription: String? {
        switch self {
        case .invalidToken:
            "The AgentGit registration token is invalid."
        case .intentMissing:
            "The AgentGit registration request no longer exists."
        case .intentExpired:
            "The AgentGit registration request has expired. Retry the blocked write operation."
        }
    }
}

public final class AgentWriteIntentStore: @unchecked Sendable {
    public static let maximumAge: TimeInterval = 15 * 60

    private let directoryURL: URL

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL.standardizedFileURL
    }

    public static func defaultDirectoryURL(
        fileManager: FileManager = .default
    ) throws -> URL {
        let applicationSupportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return applicationSupportURL
            .appendingPathComponent("AgentGit", isDirectory: true)
            .appendingPathComponent("pending-write-intents", isDirectory: true)
    }

    public func save(_ intent: AgentWriteIntent) throws {
        try prepareDirectory()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let fileURL = try fileURL(for: intent.id.uuidString)
        try encoder.encode(intent).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    public func load(
        token: String,
        now: Date = Date()
    ) throws -> AgentWriteIntent {
        let fileURL = try fileURL(for: token)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AgentWriteIntentStoreError.intentMissing
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let intent = try decoder.decode(
            AgentWriteIntent.self,
            from: Data(contentsOf: fileURL)
        )
        guard now.timeIntervalSince(intent.createdAt) <= Self.maximumAge else {
            try? FileManager.default.removeItem(at: fileURL)
            throw AgentWriteIntentStoreError.intentExpired
        }
        return intent
    }

    public func remove(token: String) throws {
        let fileURL = try fileURL(for: token)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    public func activeIntents(
        provider: AgentProvider,
        sessionID: String,
        worktreePath: String,
        now: Date = Date()
    ) -> [AgentWriteIntent] {
        let fileURLs = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return fileURLs.compactMap { fileURL in
            guard fileURL.pathExtension == "json",
                  let intent = try? load(
                    token: fileURL.deletingPathExtension().lastPathComponent,
                    now: now
                  ),
                  intent.provider == provider,
                  intent.sessionID == sessionID,
                  intent.worktreePath == worktreePath else {
                return nil
            }
            return intent
        }.sorted { $0.createdAt > $1.createdAt }
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
    }

    private func fileURL(for token: String) throws -> URL {
        guard let token = UUID(uuidString: token)?.uuidString.lowercased() else {
            throw AgentWriteIntentStoreError.invalidToken
        }
        return directoryURL.appendingPathComponent(
            "\(token).json",
            isDirectory: false
        )
    }
}

public final class AgentWriteRegistrationResponseStore: @unchecked Sendable {
    private let directoryURL: URL

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL.standardizedFileURL
    }

    public static func defaultDirectoryURL(
        fileManager: FileManager = .default
    ) -> URL {
        fileManager.temporaryDirectory
            .appendingPathComponent("AgentGit", isDirectory: true)
            .appendingPathComponent("registration-responses", isDirectory: true)
    }

    public func save(_ response: AgentWriteRegistrationResponse) throws {
        try prepareDirectory()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let fileURL = fileURL(for: response.token)
        try encoder.encode(response).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    public func load(token: UUID) throws -> AgentWriteRegistrationResponse? {
        let fileURL = fileURL(for: token)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            AgentWriteRegistrationResponse.self,
            from: Data(contentsOf: fileURL)
        )
    }

    public func remove(token: UUID) throws {
        let fileURL = fileURL(for: token)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
    }

    private func fileURL(for token: UUID) -> URL {
        directoryURL.appendingPathComponent(
            "\(token.uuidString.lowercased()).json",
            isDirectory: false
        )
    }
}

public struct AgentWriteRegistrationGuard: Sendable {
    private let associationStore: AgentAssociationStore
    private let intentStore: AgentWriteIntentStore
    private let responseStore: AgentWriteRegistrationResponseStore
    private let auditStore: AgentRegistrationAuditStore

    public init(
        associationStore: AgentAssociationStore,
        intentStore: AgentWriteIntentStore,
        responseStore: AgentWriteRegistrationResponseStore,
        auditStore: AgentRegistrationAuditStore
    ) {
        self.associationStore = associationStore
        self.intentStore = intentStore
        self.responseStore = responseStore
        self.auditStore = auditStore
    }

    public func evaluate(
        provider: AgentProvider,
        event: AgentHookEvent,
        inheritedSessionID: String? = nil,
        now: Date = Date()
    ) -> AgentWriteGuardDecision {
        let command = shellCommand(for: event)
        if isSkillRegistrationCommand(command) {
            return .allow
        }
        if isSkillDefinitionReadCommand(command) {
            return .allow
        }
        guard isWriteCapableTool(event) else {
            return .allow
        }
        guard let candidateURL = candidateURL(for: event),
              let worktreeURL = AgentWorktreeLocator.root(
                  containing: candidateURL
              ) else {
            return .allow
        }
        guard let sessionID = event.sessionID ?? inheritedSessionID,
              !sessionID.isEmpty else {
            return .blocked(
                "AgentGit could not identify this agent session. Retry in a session that exposes a session ID."
            )
        }
        do {
            let worktreePath = worktreeURL.standardizedFileURL.path
            if try associationStore.list().contains(where: {
                $0.provider == provider
                    && $0.sessionID == sessionID
                    && $0.worktreePath == worktreePath
            }) {
                return .allow
            }
            for intent in intentStore.activeIntents(
                provider: provider,
                sessionID: sessionID,
                worktreePath: worktreePath,
                now: now
            ) {
                guard let response = try responseStore.load(token: intent.id),
                      response.provider == intent.provider,
                      response.sessionID == intent.sessionID,
                      response.worktreePath == intent.worktreePath else {
                    continue
                }
                let association = AgentAssociation(
                    provider: intent.provider,
                    sessionID: intent.sessionID,
                    worktreePath: intent.worktreePath,
                    title: response.title,
                    updatedAt: now
                )
                _ = try associationStore.upsert(association)
                let summarySuffix = response.summary.isEmpty
                    ? ""
                    : " \(response.summary)"
                _ = try? auditStore.record(
                    AgentRegistrationEvent(
                        provider: intent.provider,
                        action: .register,
                        outcome: .succeeded,
                        sessionID: intent.sessionID,
                        worktreePath: intent.worktreePath,
                        message: "Registered by agentgit-register before \(intent.toolName)."
                            + summarySuffix,
                        createdAt: now
                    )
                )
                try intentStore.remove(token: intent.id.uuidString)
                try responseStore.remove(token: intent.id)
                return .allow
            }
            let intent = AgentWriteIntent(
                provider: provider,
                sessionID: sessionID,
                worktreePath: worktreePath,
                toolName: event.toolName,
                targetPath: targetPath(for: event),
                createdAt: now
            )
            try intentStore.save(intent)
            _ = try? auditStore.record(
                AgentRegistrationEvent(
                    provider: provider,
                    action: .hookRequested,
                    outcome: .requested,
                    sessionID: sessionID,
                    worktreePath: worktreePath,
                    message: "AgentGit requested session registration before \(event.toolName).",
                    createdAt: now
                )
            )
            return .registrationRequired(intent)
        } catch {
            return .blocked(error.localizedDescription)
        }
    }

    private func isWriteCapableTool(_ event: AgentHookEvent) -> Bool {
        let normalized = event.toolName
            .lowercased()
            .filter(\.isLetter)
        if [
            "edit",
            "write",
            "notebookedit",
            "applypatch",
            "multiedit"
        ].contains(normalized) {
            return true
        }
        guard let command = shellCommand(for: event) else {
            return false
        }
        return shellCommandMayModifyRepository(command)
    }

    private func isSkillRegistrationCommand(_ command: String?) -> Bool {
        guard let command,
              command.hasPrefix("AGENTGIT_SKILL_CALL=1 "),
              !command.contains("\n"),
              !command.contains(";"),
              !command.contains("&&"),
              !command.contains("||") else {
            return false
        }
        return command.contains("/bin/AgentGitHookBridge inspect --token ")
            || command.contains("/bin/AgentGitHookBridge\" inspect --token ")
            || command.contains("/scripts/register.sh ")
            || command.contains("/scripts/register.sh\"")
    }

    private func isSkillDefinitionReadCommand(_ command: String?) -> Bool {
        guard let command,
              command.contains("SKILL.md") else {
            return false
        }
        return command.components(separatedBy: "&&").allSatisfy { component in
            let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.hasPrefix("cat ")
                || trimmed.hasPrefix("wc ")
                || trimmed.hasPrefix("sed -n ")
        }
    }

    private func candidateURL(for event: AgentHookEvent) -> URL? {
        if let targetPath = targetPath(for: event) {
            if targetPath.hasPrefix("/") {
                return URL(fileURLWithPath: targetPath)
            }
            if let basePath = event.toolInput?.cwd
                ?? event.toolInput?.workdir
                ?? event.cwd
                ?? event.workdir {
                return URL(fileURLWithPath: basePath, isDirectory: true)
                    .appendingPathComponent(targetPath)
            }
        }
        guard let directory = event.toolInput?.cwd
            ?? event.toolInput?.workdir
            ?? event.cwd
            ?? event.workdir else {
            return nil
        }
        return URL(fileURLWithPath: directory, isDirectory: true)
    }

    private func targetPath(for event: AgentHookEvent) -> String? {
        event.toolInput?.filePath
            ?? event.toolInput?.path
            ?? shellCommand(for: event).flatMap { command in
                gitWorkingDirectoryPath(command) ?? redirectedTargetPath(command)
            }
    }

    private func shellCommand(for event: AgentHookEvent) -> String? {
        event.toolInput?.command ?? event.toolInput?.cmd
    }

    private func shellCommandMayModifyRepository(_ command: String) -> Bool {
        Self.shellWritePatterns.contains { pattern in
            command.range(
                of: pattern,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
        }
    }

    private func redirectedTargetPath(_ command: String) -> String? {
        let pattern = #"(?<![0-9>])>{1,2}\s*(?!/dev/null(?:\s|$))(?:\"([^\"]+)\"|'([^']+)'|([^\s;&|]+))"#
        return firstCapturedValue(in: command, pattern: pattern)
    }

    private func gitWorkingDirectoryPath(_ command: String) -> String? {
        let pattern = #"(?:^|[;&|(\n]\s*)(?:\S*/)?git\s+-C\s+(?:\"([^\"]+)\"|'([^']+)'|([^\s;&|]+))"#
        return firstCapturedValue(in: command, pattern: pattern)
    }

    private func firstCapturedValue(
        in command: String,
        pattern: String
    ) -> String? {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ), let match = expression.firstMatch(
            in: command,
            range: NSRange(command.startIndex..., in: command)
        ) else {
            return nil
        }
        for index in 1..<match.numberOfRanges {
            let range = match.range(at: index)
            if range.location != NSNotFound,
               let swiftRange = Range(range, in: command) {
                return String(command[swiftRange])
            }
        }
        return nil
    }

    private static let shellWritePatterns = [
        #"(?:^|[;&|(\n]\s*)(?:command\s+)?(?:env\s+(?:[A-Za-z_][A-Za-z0-9_]*=\S+\s+)*)?(?:\S*/)?git(?:\s+(?:-C|-c)\s+(?:\"[^\"]*\"|'[^']*'|\S+)|\s+--(?:git-dir|work-tree)(?:=(?:\"[^\"]*\"|'[^']*'|\S+)|\s+(?:\"[^\"]*\"|'[^']*'|\S+)))*\s+(?:add|am|apply|checkout|cherry-pick|commit|fetch|merge|mv|pull|push|rebase|reset|restore|revert|rm|switch|update-index)\b"#,
        #"(?:^|[;&|(\n]\s*)(?:\S*/)?git(?:\s+\S+)*\s+stash\s+(?:push|pop|apply|drop|clear|store)\b"#,
        #"(?:^|[;&|(\n]\s*)(?:\S*/)?git(?:\s+\S+)*\s+worktree\s+(?:add|remove|move|lock|unlock|prune|repair)\b"#,
        #"(?:^|[;&|(\n]\s*)(?:\S*/)?git(?:\s+\S+)*\s+branch\s+(?:-[dDmMcC]\b|--(?:delete|move|copy)\b)"#,
        #"(?:^|[;&|(\n]\s*)(?:\S*/)?git(?:\s+\S+)*\s+tag\s+(?:-[adfsu]\b|--(?:delete|annotate|force|sign)\b)"#,
        #"(?:^|[;&|(\n]\s*)(?:command\s+)?(?:\S*/)?(?:cp|mv|rm|touch|mkdir|rmdir|ln|install|rsync|tee|truncate|chmod|chown|xattr|patch|apply_patch)\b"#,
        #"(?:^|[;&|(\n]\s*)(?:\S*/)?(?:sed|perl|clang-format|swiftformat)\b[^\n;&|]*(?:\s-i(?:\s|$)|--in-place\b|--write\b)"#,
        #"(?:^|[;&|(\n]\s*)(?:\S*/)?(?:dart\s+format\b|gofmt\s+-w\b|(?:prettier|biome)\b[^\n;&|]*--write\b)"#,
        #"(?:^|[;&|(\n]\s*)(?:printf|echo|cat|jq|yq)\b[^\n;&|]*(?<![0-9>])>{1,2}\s*(?!/dev/null(?:\s|$))"#
    ]
}

public enum AgentWriteRegistrationError: LocalizedError, Equatable, Sendable {
    case invalidTitle
    case summaryTooLong

    public var errorDescription: String? {
        switch self {
        case .invalidTitle:
            "The AgentGit session title must contain 1 to 512 bytes."
        case .summaryTooLong:
            "The AgentGit operation summary must contain at most 512 bytes."
        }
    }
}

public struct AgentWriteRegistrationHandoffService: Sendable {
    private let intentStore: AgentWriteIntentStore
    private let responseStore: AgentWriteRegistrationResponseStore

    public init(
        intentStore: AgentWriteIntentStore,
        responseStore: AgentWriteRegistrationResponseStore
    ) {
        self.intentStore = intentStore
        self.responseStore = responseStore
    }

    @discardableResult
    public func prepare(
        token: String,
        title: String,
        summary: String,
        now: Date = Date()
    ) throws -> AgentWriteRegistrationResponse {
        let normalizedTitle = title.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedTitle.isEmpty,
              normalizedTitle.utf8.count <= 512 else {
            throw AgentWriteRegistrationError.invalidTitle
        }
        guard summary.utf8.count <= 512 else {
            throw AgentWriteRegistrationError.summaryTooLong
        }
        let intent = try intentStore.load(token: token, now: now)
        let response = AgentWriteRegistrationResponse(
            token: intent.id,
            provider: intent.provider,
            sessionID: intent.sessionID,
            worktreePath: intent.worktreePath,
            title: normalizedTitle,
            summary: summary,
            preparedAt: now
        )
        try responseStore.save(response)
        return response
    }
}
