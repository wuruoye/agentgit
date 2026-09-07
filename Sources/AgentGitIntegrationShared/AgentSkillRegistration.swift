import Foundation

public enum AgentSkillRegistrationState: String, Codable, Hashable, Sendable {
    case registrationRequired
    case registered
}

public struct AgentSkillRegistrationContext: Codable, Hashable, Sendable {
    public let provider: AgentProvider
    public let sessionID: String
    public let worktreePath: String
    public let title: String
    public let state: AgentSkillRegistrationState

    public init(
        provider: AgentProvider,
        sessionID: String,
        worktreePath: String,
        title: String,
        state: AgentSkillRegistrationState
    ) {
        self.provider = provider
        self.sessionID = sessionID
        self.worktreePath = URL(fileURLWithPath: worktreePath)
            .standardizedFileURL.path
        self.title = title
        self.state = state
    }
}

public enum AgentSkillRegistrationError: LocalizedError, Equatable, Sendable {
    case invalidSessionID
    case repositoryMissing
    case titleTooLong
    case summaryTooLong

    public var errorDescription: String? {
        switch self {
        case .invalidSessionID:
            "Agent session ID is missing or exceeds 256 bytes."
        case .repositoryMissing:
            "The current directory is not inside a Git worktree."
        case .titleTooLong:
            "Agent session title must contain at most 80 characters."
        case .summaryTooLong:
            "Agent operation summary must contain at most 200 characters."
        }
    }
}

public struct AgentSkillRegistrationService: Sendable {
    private let associationStore: AgentAssociationStore
    private let auditStore: AgentRegistrationAuditStore

    public init(
        associationStore: AgentAssociationStore,
        auditStore: AgentRegistrationAuditStore
    ) {
        self.associationStore = associationStore
        self.auditStore = auditStore
    }

    public func status(
        provider: AgentProvider,
        sessionID: String,
        candidateURL: URL,
        now: Date = Date()
    ) throws -> AgentSkillRegistrationContext {
        try validateSessionID(sessionID)
        let worktreePath = try resolveWorktreePath(candidateURL)
        guard let existing = try associationStore.list().first(where: {
            $0.provider == provider
                && $0.sessionID == sessionID
                && $0.worktreePath == worktreePath
        }) else {
            return AgentSkillRegistrationContext(
                provider: provider,
                sessionID: sessionID,
                worktreePath: worktreePath,
                title: "",
                state: .registrationRequired
            )
        }
        return AgentSkillRegistrationContext(
            provider: provider,
            sessionID: sessionID,
            worktreePath: worktreePath,
            title: existing.title,
            state: .registered
        )
    }

    public func register(
        provider: AgentProvider,
        sessionID: String,
        candidateURL: URL,
        title: String = "",
        summary: String = "",
        now: Date = Date()
    ) throws -> AgentSkillRegistrationContext {
        try validateSessionID(sessionID)
        let worktreePath = try resolveWorktreePath(candidateURL)
        let normalizedTitle = title.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let normalizedSummary = summary.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard normalizedTitle.count <= 80 else {
            throw AgentSkillRegistrationError.titleTooLong
        }
        guard normalizedSummary.count <= 200 else {
            throw AgentSkillRegistrationError.summaryTooLong
        }
        let saved = try associationStore.upsert(
            AgentAssociation(
                provider: provider,
                sessionID: sessionID,
                worktreePath: worktreePath,
                title: normalizedTitle,
                updatedAt: now
            ), minimumRefreshInterval: 60
        )
        let savedTitle = saved.first {
            $0.provider == provider && $0.sessionID == sessionID && $0.worktreePath == worktreePath
        }?.title ?? normalizedTitle
        let summarySuffix = normalizedSummary.isEmpty
            ? ""
            : " \(normalizedSummary)"
        _ = try? auditStore.record(
            AgentRegistrationEvent(
                provider: provider,
                action: .register,
                outcome: .succeeded,
                sessionID: sessionID,
                worktreePath: worktreePath,
                message: "Session linked.\(summarySuffix)",
                createdAt: now
            ), minimumInterval: 60
        )
        return AgentSkillRegistrationContext(
            provider: provider,
            sessionID: sessionID,
            worktreePath: worktreePath,
            title: savedTitle,
            state: .registered
        )
    }

    private func validateSessionID(_ sessionID: String) throws {
        guard !sessionID.isEmpty,
              sessionID.utf8.count <= 256 else {
            throw AgentSkillRegistrationError.invalidSessionID
        }
    }

    private func resolveWorktreePath(_ candidateURL: URL) throws -> String {
        guard candidateURL.path.hasPrefix("/"),
              let worktreeURL = AgentWorktreeLocator.root(
                  containing: candidateURL
              ) else {
            throw AgentSkillRegistrationError.repositoryMissing
        }
        return worktreeURL.standardizedFileURL.path
    }
}
