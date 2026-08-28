import Darwin
import Foundation

public enum AgentRegistrationAction: String, Codable, Hashable, Sendable {
    case register
    case unregister
}

public enum AgentRegistrationOutcome: String, Codable, Hashable, Sendable {
    case succeeded
    case rejected
    case failed
}

public struct AgentRegistrationEvent: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let provider: AgentProvider
    public let action: AgentRegistrationAction
    public let outcome: AgentRegistrationOutcome
    public let sessionID: String?
    public let worktreePath: String?
    public let message: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        provider: AgentProvider,
        action: AgentRegistrationAction,
        outcome: AgentRegistrationOutcome,
        sessionID: String?,
        worktreePath: String?,
        message: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.provider = provider
        self.action = action
        self.outcome = outcome
        self.sessionID = sessionID
        self.worktreePath = worktreePath.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }
        self.message = message
        self.createdAt = createdAt
    }
}

public final class AgentRegistrationAuditStore: @unchecked Sendable {
    private static let processLock = NSLock()
    private static let maximumEventCount = 200

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
            .appendingPathComponent("registration-events.json", isDirectory: false)
    }

    @discardableResult
    public func record(_ event: AgentRegistrationEvent) throws -> [AgentRegistrationEvent] {
        try withLock {
            var events = try loadLocked().events
            events.removeAll { $0.id == event.id }
            events.append(event)
            events.sort(by: Self.compare)
            if events.count > Self.maximumEventCount {
                events.removeLast(events.count - Self.maximumEventCount)
            }
            try saveLocked(events)
            DistributedNotificationCenter.default().postNotificationName(
                AgentIntegrationContract.registrationAuditChangedNotification,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            return events
        }
    }

    public func list() throws -> [AgentRegistrationEvent] {
        try withLock {
            let result = try loadLocked()
            if result.discardedCount > 0 {
                try saveLocked(result.events)
            }
            return result.events
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
            DistributedNotificationCenter.default().postNotificationName(
                AgentIntegrationContract.registrationAuditChangedNotification,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
        }
        return backupURL
    }

    private func loadLocked() throws -> RegistrationEventLoadResult {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return RegistrationEventLoadResult(events: [], discardedCount: 0)
        }
        let data = try Data(contentsOf: storeURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let decoded = try decoder.decode(
                [LossyDecodable<AgentRegistrationEvent>].self,
                from: data
            )
            let events = decoded.compactMap(\.value).sorted(by: Self.compare)
            return RegistrationEventLoadResult(
                events: events,
                discardedCount: decoded.count - events.count
            )
        } catch {
            throw AgentPersistenceStoreError.invalidRegistrationEvents
        }
    }

    private func saveLocked(_ events: [AgentRegistrationEvent]) throws {
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
        try encoder.encode(events).write(to: storeURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: storeURL.path
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

    private static func compare(
        _ lhs: AgentRegistrationEvent,
        _ rhs: AgentRegistrationEvent
    ) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

private struct RegistrationEventLoadResult {
    let events: [AgentRegistrationEvent]
    let discardedCount: Int
}

private struct LossyDecodable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}
