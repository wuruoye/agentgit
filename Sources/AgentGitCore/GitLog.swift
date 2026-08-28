import Foundation

public struct GitCommit: Identifiable, Hashable, Codable, Sendable {
    public let oid: String
    public let shortOID: String
    public let authorName: String
    public let authoredAt: Date
    public let parentOIDs: [String]
    public let refNames: [String]
    public let subject: String

    public init(
        oid: String,
        shortOID: String,
        authorName: String,
        authoredAt: Date,
        parentOIDs: [String],
        refNames: [String],
        subject: String
    ) {
        self.oid = oid
        self.shortOID = shortOID
        self.authorName = authorName
        self.authoredAt = authoredAt
        self.parentOIDs = parentOIDs
        self.refNames = refNames
        self.subject = subject
    }

    public var id: String {
        oid
    }

    public var isMerge: Bool {
        parentOIDs.count > 1
    }

    public var references: [GitReferenceDecoration] {
        GitReferenceDecoration.parse(refNames)
    }
}

public enum GitReferenceKind: Int, Hashable, Sendable {
    case head
    case localBranch
    case tag
    case remoteBranch
    case other
}

public struct GitReferenceDecoration: Identifiable, Hashable, Sendable {
    public let kind: GitReferenceKind
    public let label: String
    public let fullName: String

    public var id: String {
        "\(kind.rawValue):\(fullName)"
    }

    public static func parse(_ names: [String]) -> [GitReferenceDecoration] {
        var seen: Set<String> = []
        return names.compactMap { rawName in
            let decoration = decoration(rawName)
            guard seen.insert(decoration.id).inserted else {
                return nil
            }
            return decoration
        }.sorted { lhs, rhs in
            if lhs.kind.rawValue != rhs.kind.rawValue {
                return lhs.kind.rawValue < rhs.kind.rawValue
            }
            return lhs.label.localizedStandardCompare(rhs.label) == .orderedAscending
        }
    }

    private static func decoration(_ rawName: String) -> GitReferenceDecoration {
        if rawName == "HEAD" {
            return GitReferenceDecoration(kind: .head, label: "HEAD", fullName: rawName)
        }
        if rawName.hasPrefix("HEAD -> ") {
            let target = String(rawName.dropFirst("HEAD -> ".count))
            return GitReferenceDecoration(
                kind: .head,
                label: shortName(target),
                fullName: target
            )
        }
        if rawName.hasPrefix("tag: ") {
            let target = String(rawName.dropFirst("tag: ".count))
            return GitReferenceDecoration(
                kind: .tag,
                label: target.removingPrefix("refs/tags/"),
                fullName: target
            )
        }
        if rawName.hasPrefix("refs/heads/") {
            return GitReferenceDecoration(
                kind: .localBranch,
                label: rawName.removingPrefix("refs/heads/"),
                fullName: rawName
            )
        }
        if rawName.hasPrefix("refs/remotes/") {
            return GitReferenceDecoration(
                kind: .remoteBranch,
                label: rawName.removingPrefix("refs/remotes/"),
                fullName: rawName
            )
        }
        return GitReferenceDecoration(
            kind: .other,
            label: shortName(rawName),
            fullName: rawName
        )
    }

    private static func shortName(_ name: String) -> String {
        name.removingPrefix("refs/heads/")
            .removingPrefix("refs/remotes/")
            .removingPrefix("refs/tags/")
    }
}

public struct GitHistoryPage: Equatable, Codable, Sendable {
    public let commits: [GitCommit]
    public let nextOffset: Int
    public let hasMore: Bool

    public init(commits: [GitCommit], nextOffset: Int, hasMore: Bool) {
        self.commits = commits
        self.nextOffset = nextOffset
        self.hasMore = hasMore
    }
}

public enum GitHistorySearchField: Hashable, Sendable {
    case message
    case author
}

public struct GitHistorySearchQuery: Hashable, Sendable {
    public let field: GitHistorySearchField
    public let term: String

    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        let lowercased = trimmed.lowercased()
        if lowercased.hasPrefix("author:") {
            let term = String(trimmed.dropFirst("author:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else {
                return nil
            }
            field = .author
            self.term = term
        } else if lowercased.hasPrefix("message:") {
            let term = String(trimmed.dropFirst("message:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else {
                return nil
            }
            field = .message
            self.term = term
        } else {
            field = .message
            self.term = trimmed
        }
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }
}

public enum GitLogParseError: Error, Equatable, Sendable {
    case invalidUTF8
    case malformedRecord(String)
}

public enum GitLogParser {
    /// 与 GitRepositoryService.historyFormat 对应：7 个 \u{1f} 分隔字段，记录以 NUL 分隔。
    public static func parse(_ data: Data) throws -> [GitCommit] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        return try data.split(separator: 0, omittingEmptySubsequences: true).map { record in
            guard let text = String(data: Data(record), encoding: .utf8) else {
                throw GitLogParseError.invalidUTF8
            }

            let fields = text.split(
                separator: "\u{1f}",
                maxSplits: 6,
                omittingEmptySubsequences: false
            )
            guard fields.count == 7, let authoredAt = formatter.date(from: String(fields[3])) else {
                throw GitLogParseError.malformedRecord(text)
            }

            return GitCommit(
                oid: String(fields[0]),
                shortOID: String(fields[1]),
                authorName: String(fields[2]),
                authoredAt: authoredAt,
                parentOIDs: fields[4].split(separator: " ").map(String.init),
                refNames: fields[5]
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty },
                subject: String(fields[6])
            )
        }
    }
}

public enum GitNameStatusParser {
    /// 解析 `--name-status -z`：状态与路径各占一条 NUL 记录，rename/copy 额外多一条目标路径。
    public static func parse(_ data: Data) throws -> [GitFileChange] {
        let records = data.split(separator: 0, omittingEmptySubsequences: true)
        var changes: [GitFileChange] = []
        var index = 0

        while index < records.count {
            guard let status = String(data: Data(records[index]), encoding: .utf8) else {
                throw GitStatusParseError.invalidUTF8
            }
            index += 1

            guard let code = status.first else {
                throw GitStatusParseError.malformedRecord(status)
            }
            let isRenameOrCopy = code == "R" || code == "C"
            let pathCount = isRenameOrCopy ? 2 : 1
            guard index + pathCount <= records.count else {
                throw GitStatusParseError.malformedRecord(status)
            }

            let paths = try records[index ..< index + pathCount].map { record -> String in
                guard let path = String(data: Data(record), encoding: .utf8) else {
                    throw GitStatusParseError.invalidUTF8
                }
                return path
            }
            index += pathCount

            changes.append(
                GitFileChange(
                    path: paths.last ?? "",
                    originalPath: isRenameOrCopy ? paths.first : nil,
                    indexStatus: code,
                    worktreeStatus: code,
                    kind: isRenameOrCopy ? .renamedOrCopied : .ordinary
                )
            )
        }

        return changes
    }
}
