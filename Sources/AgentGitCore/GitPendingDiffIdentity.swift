import CryptoKit
import Foundation

/// 文件的两侧内容与解析条件；不随其他文件的 status、numstat 或活动时间变化。
/// 忽略空白只影响显示，不进身份；上下文行数会改变 Git 输出的正文，留在身份里。
public struct GitPendingDiffIdentity: Hashable, Codable, Sendable {
    public let worktreeID: GitWorktree.ID
    public let changeID: GitFileChange.ID
    public let status: String
    public let scope: GitDiffScope
    public let context: GitDiffContext
    public let oldContent: [String]
    public let newContent: [String]
    public let attributes: [String]
    public let configuration: String
    /// 没有指定 diff 驱动时，hunk 标题按 Git 默认规则找，可以从上下文更多的结果里重算。
    public let usesDefaultFunctionNames: Bool

    public func matchesContent(of other: GitPendingDiffIdentity) -> Bool {
        worktreeID == other.worktreeID && changeID == other.changeID && status == other.status && scope == other.scope
            && oldContent == other.oldContent && newContent == other.newContent
            && attributes == other.attributes && configuration == other.configuration
    }

    public func withContext(_ context: GitDiffContext) -> GitPendingDiffIdentity {
        GitPendingDiffIdentity(
            worktreeID: worktreeID, changeID: changeID, status: status, scope: scope, context: context,
            oldContent: oldContent, newContent: newContent, attributes: attributes,
            configuration: configuration, usesDefaultFunctionNames: usesDefaultFunctionNames
        )
    }
}

extension GitRepositoryService {
    /// 按文件读取对象与属性；未变的工作区文件沿用已计算的内容哈希。
    @concurrent public func pendingDiffIdentities(
        worktree: GitWorktree,
        workingChanges: [GitFileChange],
        stagedChanges: [GitFileChange],
        options: GitDiffOptions
    ) async throws -> [GitPendingDiffIdentity] {
        let changes = workingChanges + stagedChanges
        // 忽略空白的 Git 输出由显示层从完整 diff 推出，不按内容身份复用。
        guard !changes.isEmpty, !options.ignoresWhitespace else { return [] }
        let paths = Set(changes.flatMap { [$0.path, $0.originalPath].compactMap { $0 } }).sorted()
        let reader = GitPendingIdentityReader(runner: runner, rootURL: worktree.rootURL)
        guard let metadata = try await pendingIdentityCache.metadata(
            reader: reader, paths: paths, needsHead: !stagedChanges.isEmpty, isUnborn: worktree.isUnborn
        ) else { return [] }
        let headOID = metadata.headOID
        let configuration = metadata.configuration
        let attributes = metadata.attributes
        guard let objects = try await pendingIdentityCache.objects(
            reader: reader, paths: paths, headOID: stagedChanges.isEmpty ? nil : headOID
        ) else { return [] }
        let indexObjects = objects.index
        let headObjects = objects.head
        var remainingBytes = 64 * 1_024 * 1_024
        var workingContent: [String: String] = [:]
        var identities: [GitPendingDiffIdentity] = []
        for (scope, scopedChanges) in [(GitDiffScope.working, workingChanges), (.staged, stagedChanges)] {
            for change in scopedChanges {
                try Task.checkCancellation()
                guard change.kind != .unmerged, change.submoduleStatus == nil else { continue }
                // clean filter 和 textconv 与 Git 自己的假设一致：同样的内容和配置得到同样的结果。
                // 驱动命令写在配置里，已经算进 configuration。
                let filePaths = [change.path, change.originalPath].compactMap { $0 }
                guard !filePaths.contains(where: {
                    indexObjects[$0]?.hasPrefix("160000 ") == true || headObjects[$0]?.hasPrefix("160000 ") == true
                }) else { continue }
                let oldContent = filePaths.map {
                    scope == .staged ? headObjects[$0] ?? "absent" : indexObjects[$0] ?? "absent"
                }
                let newContent: [String]
                if scope == .staged {
                    newContent = filePaths.map { indexObjects[$0] ?? "absent" }
                } else {
                    for path in filePaths where workingContent[path] == nil {
                        do {
                            let url = worktree.rootURL.appendingPathComponent(path).standardizedFileURL
                            guard url.path.hasPrefix(worktree.rootURL.standardizedFileURL.path + "/") else { continue }
                            let content = try await pendingIdentityCache.fileContent(
                                at: url, maximumBytes: remainingBytes
                            )
                            remainingBytes = max(0, remainingBytes - content.bytesRead)
                            workingContent[path] = content.value
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            continue
                        }
                    }
                    guard filePaths.allSatisfy({ workingContent[$0] != nil }) else { continue }
                    newContent = filePaths.compactMap { workingContent[$0] }
                }
                identities.append(GitPendingDiffIdentity(
                    worktreeID: worktree.id, changeID: change.id,
                    status: String(scope == .staged ? change.indexStatus : change.worktreeStatus),
                    scope: scope, context: options.context,
                    oldContent: oldContent, newContent: newContent,
                    attributes: filePaths.map { path in
                        let data = try? JSONEncoder().encode((attributes[path] ?? []).sorted())
                        return GitPendingIdentityReader.digest(data ?? Data())
                    },
                    configuration: configuration,
                    usesDefaultFunctionNames: !metadata.definesDefaultFunctionNames && filePaths.allSatisfy { path in
                        (attributes[path] ?? []).allSatisfy { !$0.hasPrefix("diff=") || $0 == "diff=set" }
                    }
                ))
            }
        }
        return identities
    }
}

struct GitPendingIdentityReader: Sendable {
    let runner: GitCommandRunner
    let rootURL: URL

    func run(_ arguments: [String], input: Data? = nil) async throws -> Data {
        try await runner.run(
            arguments: arguments, workingDirectory: rootURL, standardInput: input,
            maximumOutputBytes: 4 * 1_024 * 1_024, maximumErrorBytes: 64 * 1_024,
            environment: ["GIT_NO_LAZY_FETCH": "1", "GIT_LITERAL_PATHSPECS": "1"], timeout: .seconds(15)
        )
    }

    static func pathBatches(_ paths: [String]) -> [[String]] {
        var batches: [[String]] = []
        var batch: [String] = []
        var bytes = 0
        for path in paths {
            if !batch.isEmpty && (bytes + path.utf8.count > 32 * 1_024 || batch.count == 256) {
                batches.append(batch)
                batch = []
                bytes = 0
            }
            batch.append(path)
            bytes += path.utf8.count + 1
        }
        if !batch.isEmpty { batches.append(batch) }
        return batches
    }

    static func objects(_ data: Data, index: Bool) throws -> [String: String] {
        var objects: [String: String] = [:]
        for record in data.split(separator: 0) {
            guard let value = String(data: Data(record), encoding: .utf8),
                  let separator = value.firstIndex(of: "\t") else { throw CocoaError(.fileReadCorruptFile) }
            let header = value[..<separator].split(separator: " ")
            guard header.count == 3 else { throw CocoaError(.fileReadCorruptFile) }
            if index && header[2] != "0" { continue }
            let path = String(value[value.index(after: separator)...])
            objects[path] = "\(header[0]) \(index ? header[1] : header[2])"
        }
        return objects
    }

    static func digest(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
