import Foundation

public struct GitProject: Identifiable, Hashable, Sendable {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    public var id: String {
        rootURL.path
    }

    public var displayName: String {
        rootURL.lastPathComponent
    }
}

public struct GitWorktree: Identifiable, Hashable, Sendable {
    public let rootURL: URL
    public let headOID: String?
    public let branchRef: String?
    public let isBare: Bool
    public let isDetached: Bool
    public let lockedReason: String?
    public let prunableReason: String?

    public init(
        rootURL: URL,
        headOID: String?,
        branchRef: String?,
        isBare: Bool,
        isDetached: Bool,
        lockedReason: String?,
        prunableReason: String?
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.headOID = headOID
        self.branchRef = branchRef
        self.isBare = isBare
        self.isDetached = isDetached
        self.lockedReason = lockedReason
        self.prunableReason = prunableReason
    }

    public var id: String {
        rootURL.path
    }

    /// worktree list 对 unborn branch 输出全零 OID；此时 HEAD 不可作为 diff 基准。
    public var isUnborn: Bool {
        guard let headOID else {
            return true
        }
        return headOID.allSatisfy { $0 == "0" }
    }

    public var shortHeadOID: String? {
        guard let headOID, !isUnborn else {
            return nil
        }
        return String(headOID.prefix(7))
    }

    public var branchName: String? {
        guard let branchRef else {
            return nil
        }

        let prefix = "refs/heads/"
        guard branchRef.hasPrefix(prefix) else {
            return branchRef
        }
        return String(branchRef.dropFirst(prefix.count))
    }

    public var displayName: String {
        branchName ?? (isDetached ? "Detached HEAD" : rootURL.lastPathComponent)
    }
}
