import Darwin
import Foundation

public enum AgentProvider: String, Codable, CaseIterable, Hashable, Sendable {
    case codex
    case claude

    public var displayName: String {
        rawValue.capitalized
    }
}

public struct AgentAssociation: Codable, Hashable, Identifiable, Sendable {
    public let provider: AgentProvider
    public let sessionID: String
    public let worktreePath: String
    public let title: String
    public let updatedAt: Date

    public init(
        provider: AgentProvider,
        sessionID: String,
        worktreePath: String,
        title: String,
        updatedAt: Date
    ) {
        self.provider = provider
        self.sessionID = sessionID
        self.worktreePath = URL(fileURLWithPath: worktreePath).standardizedFileURL.path
        self.title = title
        self.updatedAt = updatedAt
    }

    public var id: String {
        "\(provider.rawValue):\(sessionID)"
    }

}

public enum AgentIntegrationContract {
    public static let changedNotification = Notification.Name(
        "com.sigma.agentgit.associations.changed"
    )
    public static let registrationAuditChangedNotification = Notification.Name(
        "com.sigma.agentgit.registration-audit.changed"
    )
}

public enum AgentAssociationStoreError: LocalizedError, Equatable, Sendable {
    case invalidSessionID
    case invalidWorktreePath
    case titleTooLong

    public var errorDescription: String? {
        switch self {
        case .invalidSessionID:
            "Agent session ID is missing or exceeds 256 bytes."
        case .invalidWorktreePath:
            "Worktree path must be an absolute path of at most 4096 bytes."
        case .titleTooLong:
            "Agent session title must contain at most 512 bytes."
        }
    }
}

public enum AgentPersistenceStoreError: LocalizedError, CustomStringConvertible, Equatable, Sendable {
    case invalidAssociations
    case invalidRegistrationEvents

    public var errorDescription: String? {
        switch self {
        case .invalidAssociations:
            "Agent associations contain invalid data."
        case .invalidRegistrationEvents:
            "Registration history contains invalid data."
        }
    }

    public var description: String {
        errorDescription ?? "Agent session storage is unavailable."
    }
}

public final class AgentAssociationStore: @unchecked Sendable {
    private static let processLock = NSLock()

    private let storeURL: URL

    public init(storeURL: URL) {
        self.storeURL = storeURL.standardizedFileURL
    }

    public static func defaultStoreURL(
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
            .appendingPathComponent("associations.json", isDirectory: false)
    }

    public func upsert(_ association: AgentAssociation) throws -> [AgentAssociation] {
        try validate(association)
        return try withLock {
            var associations = try loadLocked()
            let retainedTitle = association.title.isEmpty
                ? associations.first(where: { $0.id == association.id })?.title ?? ""
                : association.title
            let storedAssociation = AgentAssociation(
                provider: association.provider,
                sessionID: association.sessionID,
                worktreePath: association.worktreePath,
                title: retainedTitle,
                updatedAt: association.updatedAt
            )
            associations.removeAll { $0.id == association.id }
            associations.append(storedAssociation)
            associations.sort(by: Self.compare)
            try saveLocked(associations)
            postChangedNotification()
            return associations
        }
    }

    public func remove(
        provider: AgentProvider,
        sessionID: String
    ) throws -> [AgentAssociation] {
        try withLock {
            var associations = try loadLocked()
            associations.removeAll {
                $0.provider == provider && $0.sessionID == sessionID
            }
            try saveLocked(associations)
            postChangedNotification()
            return associations
        }
    }

    public func list() throws -> [AgentAssociation] {
        try withLock {
            try loadLocked()
        }
    }

    @discardableResult
    public func recoverCorruptFile() throws -> URL? {
        let backupURL = try withLock { () -> URL? in
            guard FileManager.default.fileExists(atPath: storeURL.path) else {
                return nil
            }
            let backupURL = Self.corruptBackupURL(for: storeURL)
            try FileManager.default.moveItem(at: storeURL, to: backupURL)
            do {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: backupURL.path
                )
                try saveLocked([])
            } catch {
                try? FileManager.default.removeItem(at: storeURL)
                try? FileManager.default.moveItem(at: backupURL, to: storeURL)
                throw error
            }
            return backupURL
        }
        if backupURL != nil {
            postChangedNotification()
        }
        return backupURL
    }

    private func validate(_ association: AgentAssociation) throws {
        guard !association.sessionID.isEmpty,
              association.sessionID.utf8.count <= 256 else {
            throw AgentAssociationStoreError.invalidSessionID
        }
        guard association.worktreePath.hasPrefix("/"),
              association.worktreePath.utf8.count <= 4_096 else {
            throw AgentAssociationStoreError.invalidWorktreePath
        }
        guard association.title.utf8.count <= 512 else {
            throw AgentAssociationStoreError.titleTooLong
        }
    }

    private func loadLocked() throws -> [AgentAssociation] {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return []
        }
        let data = try Data(contentsOf: storeURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([AgentAssociation].self, from: data)
                .sorted(by: Self.compare)
        } catch {
            throw AgentPersistenceStoreError.invalidAssociations
        }
    }

    private func saveLocked(_ associations: [AgentAssociation]) throws {
        let directoryURL = storeURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(associations).write(to: storeURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: storeURL.path
        )
    }

    private func postChangedNotification() {
        DistributedNotificationCenter.default().postNotificationName(
            AgentIntegrationContract.changedNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }

        let directoryURL = storeURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
        let lockURL = storeURL.appendingPathExtension("lock")
        let descriptor = lockURL.path.withCString { path in
            Darwin.open(path, O_CREAT | O_RDWR, mode_t(0o600))
        }
        guard descriptor >= 0 else {
            throw Self.currentPOSIXError()
        }
        defer { Darwin.close(descriptor) }
        var fileLock = Darwin.flock()
        fileLock.l_type = Int16(F_WRLCK)
        fileLock.l_whence = Int16(SEEK_SET)
        fileLock.l_start = 0
        fileLock.l_len = 0
        guard Darwin.fcntl(descriptor, F_SETLKW, &fileLock) != -1 else {
            throw Self.currentPOSIXError()
        }
        defer {
            var unlock = Darwin.flock()
            unlock.l_type = Int16(F_UNLCK)
            unlock.l_whence = Int16(SEEK_SET)
            unlock.l_start = 0
            unlock.l_len = 0
            _ = Darwin.fcntl(descriptor, F_SETLK, &unlock)
        }
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw Self.currentPOSIXError()
        }
        return try body()
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static func corruptBackupURL(for storeURL: URL) -> URL {
        let fileName = storeURL.deletingPathExtension().lastPathComponent
        let pathExtension = storeURL.pathExtension
        let backupName = "\(fileName).corrupt-\(UUID().uuidString)"
            + (pathExtension.isEmpty ? "" : ".\(pathExtension)")
        return storeURL.deletingLastPathComponent().appendingPathComponent(
            backupName,
            isDirectory: false
        )
    }

    private static func compare(_ lhs: AgentAssociation, _ rhs: AgentAssociation) -> Bool {
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        return lhs.id < rhs.id
    }
}
