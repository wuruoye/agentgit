import Foundation

public enum GitChangeKind: String, Hashable, Sendable {
    case ordinary
    case renamedOrCopied
    case unmerged
    case untracked
}

public struct GitFileChange: Identifiable, Hashable, Sendable {
    public let path: String
    public let originalPath: String?
    public let indexStatus: Character
    public let worktreeStatus: Character
    public let kind: GitChangeKind

    public init(
        path: String,
        originalPath: String?,
        indexStatus: Character,
        worktreeStatus: Character,
        kind: GitChangeKind
    ) {
        self.path = path
        self.originalPath = originalPath
        self.indexStatus = indexStatus
        self.worktreeStatus = worktreeStatus
        self.kind = kind
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

public struct GitBranchStatus: Hashable, Sendable {
    public let upstreamRef: String?
    public let aheadCount: Int
    public let behindCount: Int

    public init(upstreamRef: String?, aheadCount: Int, behindCount: Int) {
        self.upstreamRef = upstreamRef
        self.aheadCount = aheadCount
        self.behindCount = behindCount
    }

    public var isSynced: Bool {
        aheadCount == 0 && behindCount == 0
    }
}

public struct GitStatusSnapshot: Hashable, Sendable {
    public let changes: [GitFileChange]
    public let branch: GitBranchStatus?

    public init(changes: [GitFileChange], branch: GitBranchStatus? = nil) {
        self.changes = changes
        self.branch = branch
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
                if let ref = record.dropPrefix("# branch.upstream ") {
                    upstreamRef = String(ref)
                } else if let counts = record.dropPrefix("# branch.ab ") {
                    let fields = counts.split(separator: " ")
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
            }
        )
    }

    private static func makeChange(
        status: String,
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
            kind: kind
        )
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> Substring? {
        hasPrefix(prefix) ? dropFirst(prefix.count) : nil
    }
}
