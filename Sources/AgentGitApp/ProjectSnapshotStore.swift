import AgentGitCore
import Foundation

struct ProjectSnapshotCachePayload: Codable, Equatable, Sendable {
    static let schemaVersion = 2

    let version: Int
    let eventID: UInt64
    let projects: [GitProjectSnapshot]
    let completeProjectIDs: Set<GitProject.ID>

    init(
        eventID: UInt64,
        projects: [GitProjectSnapshot],
        completeProjectIDs: Set<GitProject.ID>
    ) {
        self.version = Self.schemaVersion
        self.eventID = eventID
        self.projects = projects
        self.completeProjectIDs = completeProjectIDs.intersection(
            Set(projects.map(\.id))
        )
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case eventID
        case projects
        case completeProjectIDs
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try container.decode(Int.self, forKey: .version)
        guard storedVersion == 1 || storedVersion == Self.schemaVersion else {
            throw ProjectSnapshotStoreError.unsupportedVersion(storedVersion)
        }
        let projects = try container.decode(
            [GitProjectSnapshot].self,
            forKey: .projects
        )
        try Self.validateUniqueIdentities(in: projects)
        let availableProjectIDs = Set(projects.map(\.id))
        let completeProjectIDs: Set<GitProject.ID>
        if storedVersion == 1 {
            completeProjectIDs = availableProjectIDs
        } else {
            completeProjectIDs = Set(
                try container.decodeIfPresent(
                    [GitProject.ID].self,
                    forKey: .completeProjectIDs
                ) ?? []
            ).intersection(availableProjectIDs)
        }
        self.version = Self.schemaVersion
        self.eventID = try container.decode(UInt64.self, forKey: .eventID)
        self.projects = projects
        self.completeProjectIDs = completeProjectIDs
    }

    private static func validateUniqueIdentities(
        in projects: [GitProjectSnapshot]
    ) throws {
        var projectIDs: Set<GitProject.ID> = []
        var worktreeIDs: Set<GitWorktree.ID> = []
        for project in projects {
            guard projectIDs.insert(project.id).inserted else {
                throw ProjectSnapshotStoreError.duplicateProjectID(project.id)
            }
            for worktree in project.worktrees {
                guard worktreeIDs.insert(worktree.id).inserted else {
                    throw ProjectSnapshotStoreError.duplicateWorktreeID(
                        worktree.id
                    )
                }
            }
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schemaVersion, forKey: .version)
        try container.encode(eventID, forKey: .eventID)
        try container.encode(projects, forKey: .projects)
        try container.encode(
            completeProjectIDs.sorted(),
            forKey: .completeProjectIDs
        )
    }
}

enum ProjectSnapshotStoreError: Error, CustomStringConvertible, Sendable {
    case unsupportedVersion(Int)
    case duplicateProjectID(GitProject.ID)
    case duplicateWorktreeID(GitWorktree.ID)

    var description: String {
        switch self {
        case let .unsupportedVersion(version):
            "Unsupported project snapshot cache version: \(version)."
        case let .duplicateProjectID(projectID):
            "Project snapshot cache contains duplicate project ID: \(projectID)."
        case let .duplicateWorktreeID(worktreeID):
            "Project snapshot cache contains duplicate worktree ID: \(worktreeID)."
        }
    }
}

actor ProjectSnapshotStore {
    nonisolated let fileURL: URL
    nonisolated let initialPayload: ProjectSnapshotCachePayload?
    nonisolated let initialErrorMessage: String?

    private var payload: ProjectSnapshotCachePayload?

    init(fileURL: URL) {
        self.fileURL = fileURL.standardizedFileURL
        do {
            let loaded = try Self.loadRecoveringBackup(from: self.fileURL)
            self.initialPayload = loaded
            self.initialErrorMessage = nil
            self.payload = loaded
        } catch {
            self.initialPayload = nil
            self.initialErrorMessage = String(describing: error)
            self.payload = nil
        }
    }

    func save(
        projectIDs: [GitProject.ID],
        snapshots: [GitProjectSnapshot],
        eventID: UInt64,
        completeProjectIDs: Set<GitProject.ID>
    ) throws {
        let previousByProjectID = Dictionary(
            (payload?.projects ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        let currentByProjectID = Dictionary(
            snapshots.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        let projects = projectIDs.compactMap { projectID -> GitProjectSnapshot? in
            guard let current = currentByProjectID[projectID] else {
                return previousByProjectID[projectID]
            }
            let previousByWorktreeID = Dictionary(
                (previousByProjectID[projectID]?.worktrees ?? []).map {
                    ($0.id, $0)
                },
                uniquingKeysWith: { _, latest in latest }
            )
            let worktrees = current.worktrees.compactMap { worktree in
                if worktree.hasUsableState, worktree.errorMessage == nil {
                    return Self.sanitized(worktree)
                }
                return previousByWorktreeID[worktree.id]
            }
            return GitProjectSnapshot(
                project: current.project,
                worktrees: worktrees,
                refreshedAt: current.refreshedAt
            )
        }
        let nextPayload = ProjectSnapshotCachePayload(
            eventID: eventID,
            projects: projects,
            completeProjectIDs: completeProjectIDs
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(nextPayload)
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try preserveCurrentSnapshotAsBackup()
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
        try createBackupIfNeeded(from: data)
        payload = nextPayload
    }

    nonisolated static var defaultFileURL: URL {
        let cacheRoot = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches", isDirectory: true)
        return cacheRoot
            .appendingPathComponent("com.sigma.agentgit", isDirectory: true)
            .appendingPathComponent("project-snapshots-v1.json", isDirectory: false)
    }

    nonisolated static func load(from fileURL: URL) throws -> ProjectSnapshotCachePayload? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let payload = try decoder.decode(ProjectSnapshotCachePayload.self, from: data)
        guard payload.version == ProjectSnapshotCachePayload.schemaVersion else {
            throw ProjectSnapshotStoreError.unsupportedVersion(payload.version)
        }
        return payload
    }

    private nonisolated static func loadRecoveringBackup(
        from fileURL: URL
    ) throws -> ProjectSnapshotCachePayload? {
        do {
            if let payload = try load(from: fileURL) {
                return payload
            }
        } catch {
            guard let backup = try? load(from: backupFileURL(for: fileURL)) else {
                throw error
            }
            try? restoreBackup(at: fileURL)
            return backup
        }

        guard let backup = try load(from: backupFileURL(for: fileURL)) else {
            return nil
        }
        try? restoreBackup(at: fileURL)
        return backup
    }

    private func preserveCurrentSnapshotAsBackup() throws {
        guard (try? Self.load(from: fileURL)) != nil else {
            return
        }
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let backupURL = Self.backupFileURL(for: fileURL)
        try data.write(to: backupURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: backupURL.path
        )
    }

    private func createBackupIfNeeded(from data: Data) throws {
        let backupURL = Self.backupFileURL(for: fileURL)
        guard !FileManager.default.fileExists(atPath: backupURL.path) else {
            return
        }
        try data.write(to: backupURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: backupURL.path
        )
    }

    private nonisolated static func restoreBackup(at fileURL: URL) throws {
        let data = try Data(
            contentsOf: backupFileURL(for: fileURL),
            options: .mappedIfSafe
        )
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    private nonisolated static func backupFileURL(for fileURL: URL) -> URL {
        fileURL.deletingPathExtension()
            .appendingPathExtension("backup")
            .appendingPathExtension("json")
    }

    private nonisolated static func sanitized(
        _ snapshot: GitWorktreeSnapshot
    ) -> GitWorktreeSnapshot {
        GitWorktreeSnapshot(
            worktree: snapshot.worktree,
            status: snapshot.status,
            diffStat: snapshot.diffStat,
            lastActivityAt: snapshot.lastActivityAt,
            refreshedAt: snapshot.refreshedAt,
            errorMessage: nil,
            hasUsableState: true,
            eventWatchURLs: snapshot.eventWatchURLs
        )
    }
}
