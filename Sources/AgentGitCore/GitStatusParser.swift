import Foundation

public enum GitChangeKind: String, Hashable, Codable, Sendable {
    case ordinary
    case renamedOrCopied
    case unmerged
    case untracked
}

public struct GitSubmoduleStatus: Hashable, Codable, Sendable {
    public let commitChanged: Bool
    public let hasTrackedChanges: Bool
    public let hasUntrackedChanges: Bool

    public init(
        commitChanged: Bool,
        hasTrackedChanges: Bool,
        hasUntrackedChanges: Bool
    ) {
        self.commitChanged = commitChanged
        self.hasTrackedChanges = hasTrackedChanges
        self.hasUntrackedChanges = hasUntrackedChanges
    }
}

public struct GitFileChange: Identifiable, Hashable, Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case path
        case originalPath
        case indexStatus
        case worktreeStatus
        case kind
        case submoduleStatus
    }

    public let path: String
    public let originalPath: String?
    public let indexStatus: Character
    public let worktreeStatus: Character
    public let kind: GitChangeKind
    public let submoduleStatus: GitSubmoduleStatus?

    public init(
        path: String,
        originalPath: String?,
        indexStatus: Character,
        worktreeStatus: Character,
        kind: GitChangeKind,
        submoduleStatus: GitSubmoduleStatus? = nil
    ) {
        self.path = path
        self.originalPath = originalPath
        self.indexStatus = indexStatus
        self.worktreeStatus = worktreeStatus
        self.kind = kind
        self.submoduleStatus = submoduleStatus
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let indexStatusValue = try container.decode(String.self, forKey: .indexStatus)
        let worktreeStatusValue = try container.decode(
            String.self,
            forKey: .worktreeStatus
        )
        guard indexStatusValue.count == 1,
              let indexStatus = indexStatusValue.first else {
            throw DecodingError.dataCorruptedError(
                forKey: .indexStatus,
                in: container,
                debugDescription: "Git index status must contain one character."
            )
        }
        guard worktreeStatusValue.count == 1,
              let worktreeStatus = worktreeStatusValue.first else {
            throw DecodingError.dataCorruptedError(
                forKey: .worktreeStatus,
                in: container,
                debugDescription: "Git worktree status must contain one character."
            )
        }
        self.init(
            path: try container.decode(String.self, forKey: .path),
            originalPath: try container.decodeIfPresent(String.self, forKey: .originalPath),
            indexStatus: indexStatus,
            worktreeStatus: worktreeStatus,
            kind: try container.decode(GitChangeKind.self, forKey: .kind),
            submoduleStatus: try container.decodeIfPresent(
                GitSubmoduleStatus.self,
                forKey: .submoduleStatus
            )
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encodeIfPresent(originalPath, forKey: .originalPath)
        try container.encode(String(indexStatus), forKey: .indexStatus)
        try container.encode(String(worktreeStatus), forKey: .worktreeStatus)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(submoduleStatus, forKey: .submoduleStatus)
    }

    public var isStaged: Bool {
        guard kind != .unmerged else {
            return false
        }
        return indexStatus != "." && indexStatus != "?"
    }

    public var isUnstaged: Bool {
        if kind == .unmerged {
            return true
        }
        return worktreeStatus != "." && worktreeStatus != "?"
    }

    public var isUntracked: Bool {
        kind == .untracked
    }

    public var id: String {
        "\(kind.rawValue):\(originalPath ?? "")->\(path)"
    }
}

public struct GitBranchStatus: Hashable, Codable, Sendable {
    public let upstreamRef: String?
    public let aheadCount: Int
    public let behindCount: Int
    public let upstreamError: String?

    public init(
        upstreamRef: String?,
        aheadCount: Int,
        behindCount: Int,
        upstreamError: String? = nil
    ) {
        self.upstreamRef = upstreamRef
        self.aheadCount = aheadCount
        self.behindCount = behindCount
        self.upstreamError = upstreamError
    }

    public var isSynced: Bool {
        aheadCount == 0 && behindCount == 0
    }
}

public struct GitStatusSnapshot: Hashable, Codable, Sendable {
    public let changes: [GitFileChange]
    public let branch: GitBranchStatus?
    public let headOID: String?
    public let branchHead: String?

    public init(
        changes: [GitFileChange],
        branch: GitBranchStatus? = nil,
        headOID: String? = nil,
        branchHead: String? = nil
    ) {
        self.changes = changes
        self.branch = branch
        self.headOID = headOID
        self.branchHead = branchHead
    }

    public static let clean = GitStatusSnapshot(changes: [])

    public var changedFileCount: Int {
        changes.count
    }

    public var stagedFileCount: Int {
        changes.count(where: \.isStaged)
    }

    public var unstagedFileCount: Int {
        changes.count(where: \.isUnstaged)
    }

    public var untrackedFileCount: Int {
        changes.count(where: \.isUntracked)
    }
}

public enum GitStatusParseError: Error, Equatable, Sendable {
    case invalidUTF8
    case malformedRecord(String)
    case missingOriginalPath(String)
}

public enum GitStatusParser {
    public static func parsePorcelainV2(_ data: Data) throws -> GitStatusSnapshot {
        let rawRecords = data.split(separator: 0, omittingEmptySubsequences: true)
        var changes: [GitFileChange] = []
        var upstreamRef: String?
        var aheadCount = 0
        var behindCount = 0
        var headOID: String?
        var branchHead: String?
        var index = 0

        while index < rawRecords.count {
            guard let record = String(data: Data(rawRecords[index]), encoding: .utf8) else {
                throw GitStatusParseError.invalidUTF8
            }
            index += 1

            guard let prefix = record.first else {
                continue
            }

            switch prefix {
            case "1":
                let fields = record.split(
                    separator: " ",
                    maxSplits: 8,
                    omittingEmptySubsequences: false
                )
                guard fields.count == 9 else {
                    throw GitStatusParseError.malformedRecord(record)
                }
                changes.append(
                    try makeChange(
                        status: String(fields[1]),
                        submodule: String(fields[2]),
                        path: String(fields[8]),
                        originalPath: nil,
                        kind: .ordinary,
                        record: record
                    )
                )

            case "2":
                let fields = record.split(
                    separator: " ",
                    maxSplits: 9,
                    omittingEmptySubsequences: false
                )
                guard fields.count == 10 else {
                    throw GitStatusParseError.malformedRecord(record)
                }
                guard index < rawRecords.count else {
                    throw GitStatusParseError.missingOriginalPath(record)
                }
                guard let originalPath = String(
                    data: Data(rawRecords[index]),
                    encoding: .utf8
                ) else {
                    throw GitStatusParseError.invalidUTF8
                }
                index += 1
                changes.append(
                    try makeChange(
                        status: String(fields[1]),
                        submodule: String(fields[2]),
                        path: String(fields[9]),
                        originalPath: originalPath,
                        kind: .renamedOrCopied,
                        record: record
                    )
                )

            case "u":
                let fields = record.split(
                    separator: " ",
                    maxSplits: 10,
                    omittingEmptySubsequences: false
                )
                guard fields.count == 11 else {
                    throw GitStatusParseError.malformedRecord(record)
                }
                changes.append(
                    try makeChange(
                        status: String(fields[1]),
                        submodule: String(fields[2]),
                        path: String(fields[10]),
                        originalPath: nil,
                        kind: .unmerged,
                        record: record
                    )
                )

            case "?":
                guard record.hasPrefix("? ") else {
                    throw GitStatusParseError.malformedRecord(record)
                }
                changes.append(
                    GitFileChange(
                        path: String(record.dropFirst(2)),
                        originalPath: nil,
                        indexStatus: "?",
                        worktreeStatus: "?",
                        kind: .untracked
                    )
                )

            case "#":
                if let oid = record.dropPrefix("# branch.oid ") {
                    let value = String(oid)
                    headOID = value == "(initial)" ? nil : value
                } else if let head = record.dropPrefix("# branch.head ") {
                    branchHead = String(head)
                } else if let ref = record.dropPrefix("# branch.upstream ") {
                    upstreamRef = String(ref)
                } else if let counts = record.dropPrefix("# branch.ab ") {
                    let fields = counts.split(separator: " ")
                    if fields.map(String.init) == ["+?", "-?"] {
                        continue
                    }
                    guard
                        fields.count == 2,
                        let ahead = Int(fields[0].dropFirst()),
                        let behind = Int(fields[1].dropFirst())
                    else {
                        throw GitStatusParseError.malformedRecord(record)
                    }
                    aheadCount = ahead
                    behindCount = behind
                }

            case "!":
                continue

            default:
                throw GitStatusParseError.malformedRecord(record)
            }
        }

        return GitStatusSnapshot(
            changes: changes,
            branch: upstreamRef.map {
                GitBranchStatus(
                    upstreamRef: $0,
                    aheadCount: aheadCount,
                    behindCount: behindCount
                )
            },
            headOID: headOID,
            branchHead: branchHead
        )
    }

    private static func makeChange(
        status: String,
        submodule: String,
        path: String,
        originalPath: String?,
        kind: GitChangeKind,
        record: String
    ) throws -> GitFileChange {
        guard status.count == 2 else {
            throw GitStatusParseError.malformedRecord(record)
        }

        return GitFileChange(
            path: path,
            originalPath: originalPath,
            indexStatus: status[status.startIndex],
            worktreeStatus: status[status.index(after: status.startIndex)],
            kind: kind,
            submoduleStatus: try parseSubmoduleStatus(submodule, record: record)
        )
    }

    private static func parseSubmoduleStatus(
        _ value: String,
        record: String
    ) throws -> GitSubmoduleStatus? {
        if value == "N..." {
            return nil
        }
        let flags = Array(value)
        guard flags.count == 4,
              flags[0] == "S",
              flags[1] == "." || flags[1] == "C",
              flags[2] == "." || flags[2] == "M",
              flags[3] == "." || flags[3] == "U" else {
            throw GitStatusParseError.malformedRecord(record)
        }
        return GitSubmoduleStatus(
            commitChanged: flags[1] == "C",
            hasTrackedChanges: flags[2] == "M",
            hasUntrackedChanges: flags[3] == "U"
        )
    }
}

public enum GitAheadBehindParser {
    public static func parse(_ data: Data, upstreamRef: String) throws -> GitBranchStatus {
        let value = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = value.split(whereSeparator: \.isWhitespace)
        guard fields.count == 2,
              let ahead = Int(fields[0]),
              let behind = Int(fields[1]) else {
            throw GitStatusParseError.malformedRecord(value)
        }
        return GitBranchStatus(
            upstreamRef: upstreamRef,
            aheadCount: ahead,
            behindCount: behind
        )
    }
}

public enum GitUntrackedFilesParser {
    public static func parse(_ data: Data) throws -> [GitFileChange] {
        try data.split(separator: 0, omittingEmptySubsequences: true).map { record in
            guard let path = String(data: Data(record), encoding: .utf8) else {
                throw GitStatusParseError.invalidUTF8
            }
            return GitFileChange(
                path: path,
                originalPath: nil,
                indexStatus: "?",
                worktreeStatus: "?",
                kind: .untracked
            )
        }
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> Substring? {
        hasPrefix(prefix) ? dropFirst(prefix.count) : nil
    }
}
