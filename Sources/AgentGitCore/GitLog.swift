import Foundation

public struct GitCommit: Identifiable, Hashable, Codable, Sendable {
    public let oid: String
    public let shortOID: String
    public let authorName: String
    public let authoredAt: Date
    public let parentOIDs: [String]
    public let refNames: [String]
    public let subject: String
    public let changedFileCount: Int?

    public init(
        oid: String,
        shortOID: String,
        authorName: String,
        authoredAt: Date,
        parentOIDs: [String],
        refNames: [String],
        subject: String,
        changedFileCount: Int? = nil
    ) {
        self.oid = oid
        self.shortOID = shortOID
        self.authorName = authorName
        self.authoredAt = authoredAt
        self.parentOIDs = parentOIDs
        self.refNames = refNames
        self.subject = subject
        self.changedFileCount = changedFileCount
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

    func withReferenceNames(_ names: [String]) -> Self {
        Self(
            oid: oid, shortOID: shortOID, authorName: authorName, authoredAt: authoredAt,
            parentOIDs: parentOIDs, refNames: names, subject: subject,
            changedFileCount: changedFileCount
        )
    }
}

public struct GitCommitMetadata: Codable, Equatable, Sendable {
    public let treeOID: String
    public let authorEmail: String

    public init(treeOID: String, authorEmail: String) {
        self.treeOID = treeOID
        self.authorEmail = authorEmail
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
    /// 7 个 \u{1f} 分隔字段；raw diff 的头和路径各占一条 NUL 记录。
    /// 保留旧 shortstat 输入的解析，行历史等没有 diff 的调用不填文件数。
    public static func parse(_ data: Data, includesRawDiffs: Bool = false) throws -> [GitCommit] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        var commits: [GitCommit] = []
        var remainingRawPaths = 0
        for record in data.split(separator: 0, omittingEmptySubsequences: true) {
            if remainingRawPaths > 0 {
                remainingRawPaths -= 1
                continue
            }
            guard let text = String(data: Data(record), encoding: .utf8) else {
                throw GitLogParseError.invalidUTF8
            }

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix(":") {
                let words = trimmed.split(separator: " ")
                guard words.count == 5, let status = words.last?.first,
                      var previous = commits.popLast() else {
                    throw GitLogParseError.malformedRecord(text)
                }
                remainingRawPaths = status == "R" || status == "C" ? 2 : 1
                previous = GitCommit(
                    oid: previous.oid, shortOID: previous.shortOID, authorName: previous.authorName,
                    authoredAt: previous.authoredAt, parentOIDs: previous.parentOIDs,
                    refNames: previous.refNames, subject: previous.subject,
                    changedFileCount: (previous.changedFileCount ?? 0) + 1
                )
                commits.append(previous)
                continue
            }

            let fields = text.split(
                separator: "\u{1f}",
                maxSplits: 6,
                omittingEmptySubsequences: false
            )
            if fields.count != 7 {
                if trimmed.isEmpty {
                    continue
                }
                guard let changedFileCount = shortStatFileCount(trimmed),
                      let previous = commits.popLast() else {
                    throw GitLogParseError.malformedRecord(text)
                }
                commits.append(
                    GitCommit(
                        oid: previous.oid,
                        shortOID: previous.shortOID,
                        authorName: previous.authorName,
                        authoredAt: previous.authoredAt,
                        parentOIDs: previous.parentOIDs,
                        refNames: previous.refNames,
                        subject: previous.subject,
                        changedFileCount: changedFileCount
                    )
                )
                continue
            }
            guard let authoredAt = formatter.date(from: String(fields[3])) else {
                throw GitLogParseError.malformedRecord(text)
            }

            commits.append(
                GitCommit(
                    oid: String(fields[0]),
                    shortOID: String(fields[1]),
                    authorName: String(fields[2]),
                    authoredAt: authoredAt,
                    parentOIDs: fields[4].split(separator: " ").map(String.init),
                    refNames: fields[5]
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty },
                    subject: String(fields[6]),
                    changedFileCount: includesRawDiffs && fields[4].split(separator: " ").count <= 1
                        ? 0 : nil
                )
            )
        }
        guard remainingRawPaths == 0 else {
            throw GitLogParseError.malformedRecord("Missing raw diff path")
        }
        return commits
    }

    private static func shortStatFileCount(_ text: String) -> Int? {
        guard let line = text.split(whereSeparator: \.isNewline).last else {
            return nil
        }
        let words = line.split(whereSeparator: \.isWhitespace)
        guard words.count >= 3,
              let count = Int(words[0]),
              words[1] == "file" || words[1] == "files",
              words[2].hasPrefix("changed") else {
            return nil
        }
        return count
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
