import CryptoKit
import Foundation

/// 创建某个 worktree 的 agent 会话。写入方：agent shell 里的 `git worktree add` 触发全局
/// post-checkout hook（`git-hook`）；Claude Desktop、Codex App 自己建的 worktree 由 AgentGit
/// 按宿主会话元数据补查（`claude-desktop`、`codex-app`）。
public struct AgentWorktreeCreator: Codable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case worktreePath = "worktree_path"
        case provider
        case sessionID = "session_id"
        case hostSessionID = "host_session_id"
        case title
        case createdAt = "created_at"
        case source
    }

    public let worktreePath: String
    public let provider: AgentProvider
    public let sessionID: String
    /// Claude Desktop 的 `local_*` 会话 ID；CLI 会话和 Codex 没有。
    public let hostSessionID: String?
    /// 记录时宿主显示的会话标题。
    public let title: String?
    public let createdAt: Date
    public let source: String

    public init(
        worktreePath: String,
        provider: AgentProvider,
        sessionID: String,
        hostSessionID: String? = nil,
        title: String? = nil,
        createdAt: Date,
        source: String
    ) {
        self.worktreePath = URL(fileURLWithPath: worktreePath).standardizedFileURL.path
        self.provider = provider
        self.sessionID = sessionID
        self.hostSessionID = hostSessionID
        self.title = title
        self.createdAt = createdAt
        self.source = source
    }
}

/// 每个 worktree 一个 JSON 文件，文件名是 worktree 路径的 SHA-256，同一路径后写的覆盖先写的。
/// hook 是 shell 脚本，按同样的规则写文件，写完用 `notifyutil -p` 发 Darwin 通知。
public struct AgentWorktreeCreatorStore: Sendable {
    public static let changedNotificationName = "com.sigma.agentgit.worktree-creators.changed"
    /// git 管理目录比记录晚这么久才创建，说明同一路径上的 worktree 删掉重建过，记录已过期。
    public static let recreationTolerance: TimeInterval = 3_600

    public let directoryURL: URL

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL.standardizedFileURL
    }

    public static func defaultDirectoryURL(
        fileManager: FileManager = .default
    ) throws -> URL {
        try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("AgentGit/worktree-creators", isDirectory: true)
    }

    public static func fileName(forWorktreePath path: String) -> String {
        SHA256.hash(data: Data(path.utf8))
            .map { String(format: "%02x", $0) }
            .joined() + ".json"
    }

    /// 仍然有效的记录，按标准化后的 worktree 路径索引（和 `GitWorktree.id` 一致）。
    public func load() -> [String: AgentWorktreeCreator] {
        scan().valid.mapValues(\.creator)
    }

    /// 删掉失效的记录文件：worktree 已删除、同一路径删掉重建过，或同一路径较旧的重复记录。
    /// git 删除 worktree 时没有 hook，由 worktree 定期清理顺带调用。
    public func removeStale() {
        for url in scan().stale {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func scan() -> (
        valid: [String: (url: URL, creator: AgentWorktreeCreator)],
        stale: [URL]
    ) {
        let decoder = makeAgentPersistenceJSONDecoder()
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )) ?? []
        var valid: [String: (url: URL, creator: AgentWorktreeCreator)] = [:]
        var stale: [URL] = []
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let creator = try? decoder.decode(AgentWorktreeCreator.self, from: data),
                  !creator.sessionID.isEmpty,
                  creator.sessionID.utf8.count <= 256 else {
                continue
            }
            let worktreeRoot = URL(fileURLWithPath: creator.worktreePath, isDirectory: true)
            guard let gitDirectoryCreatedAt = Self.gitDirectoryCreationDate(worktreeRoot: worktreeRoot) else {
                if !Self.isOnUnmountedVolume(worktreeRoot) {
                    stale.append(url)
                }
                continue
            }
            guard gitDirectoryCreatedAt <= creator.createdAt + Self.recreationTolerance else {
                stale.append(url)
                continue
            }
            let path = worktreeRoot.standardizedFileURL.path
            if let existing = valid[path] {
                guard existing.creator.createdAt < creator.createdAt else {
                    stale.append(url)
                    continue
                }
                stale.append(existing.url)
            }
            valid[path] = (url, creator)
        }
        return (valid, stale)
    }

    /// hook 认不出会话时留下的待查标记：`pending/<路径哈希>`，内容是 worktree 路径。
    public struct PendingWorktree: Sendable {
        public let worktreePath: String
        public let createdAt: Date
        let fileURL: URL
    }

    public func pendingWorktrees() -> [PendingWorktree] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL.appendingPathComponent("pending", isDirectory: true),
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.compactMap { url in
            guard let path = try? String(contentsOf: url, encoding: .utf8)
                    .trimmingCharacters(in: .newlines),
                  path.hasPrefix("/") else {
                return nil
            }
            return PendingWorktree(
                worktreePath: URL(fileURLWithPath: path).standardizedFileURL.path,
                createdAt: (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date(),
                fileURL: url
            )
        }
    }

    public func removePending(_ pending: PendingWorktree) {
        try? FileManager.default.removeItem(at: pending.fileURL)
    }

    public func save(_ creator: AgentWorktreeCreator) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = makeAgentPersistenceJSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(creator).write(
            to: directoryURL.appendingPathComponent(
                Self.fileName(forWorktreePath: creator.worktreePath)
            ),
            options: .atomic
        )
    }

    /// 外接卷没挂载时，上面的 worktree 看起来和已删除一样，记录先留着。
    private static func isOnUnmountedVolume(_ url: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        guard components.count > 2, components[1] == "Volumes" else {
            return false
        }
        return !FileManager.default.fileExists(atPath: "/Volumes/\(components[2])")
    }

    /// linked worktree 根目录下的 `.git` 文件指向它在主仓库里的管理目录。
    public static func gitDirectoryCreationDate(worktreeRoot: URL) -> Date? {
        guard let pointer = try? String(
                  contentsOf: worktreeRoot.appendingPathComponent(".git"),
                  encoding: .utf8
              ),
              pointer.hasPrefix("gitdir: ") else {
            return nil
        }
        let gitDirectory = URL(
            fileURLWithPath: pointer.dropFirst("gitdir: ".count)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            relativeTo: worktreeRoot
        )
        return try? gitDirectory.resourceValues(forKeys: [.creationDateKey]).creationDate
    }
}
