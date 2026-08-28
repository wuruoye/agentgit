import Foundation

public struct GitDiffStat: Hashable, Codable, Sendable {
    public let addedLineCount: Int
    public let deletedLineCount: Int

    public init(addedLineCount: Int, deletedLineCount: Int) {
        self.addedLineCount = addedLineCount
        self.deletedLineCount = deletedLineCount
    }

    public static let zero = GitDiffStat(addedLineCount: 0, deletedLineCount: 0)

    public var isEmpty: Bool {
        addedLineCount == 0 && deletedLineCount == 0
    }

    public static func + (lhs: GitDiffStat, rhs: GitDiffStat) -> GitDiffStat {
        GitDiffStat(
            addedLineCount: lhs.addedLineCount + rhs.addedLineCount,
            deletedLineCount: lhs.deletedLineCount + rhs.deletedLineCount
        )
    }
}

public enum GitNumstatParseError: Error, Equatable, Sendable {
    case invalidUTF8
    case malformedRecord(String)
}

public enum GitNumstatParser {
    public static func parse(_ data: Data) throws -> GitDiffStat {
        guard let text = String(data: data, encoding: .utf8) else {
            throw GitNumstatParseError.invalidUTF8
        }

        var added = 0
        var deleted = 0

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard
                fields.count == 3,
                let lineAdded = parseCount(fields[0]),
                let lineDeleted = parseCount(fields[1])
            else {
                throw GitNumstatParseError.malformedRecord(String(line))
            }
            added += lineAdded
            deleted += lineDeleted
        }

        return GitDiffStat(addedLineCount: added, deletedLineCount: deleted)
    }

    private static func parseCount(_ field: Substring) -> Int? {
        if field == "-" {
            return 0
        }
        return Int(field)
    }
}
