import Foundation

public enum GitDiffScope: String, CaseIterable, Identifiable, Hashable, Sendable {
    case working
    case staged

    public var id: Self {
        self
    }

    public var title: String {
        switch self {
        case .working: "Working"
        case .staged: "Staged"
        }
    }
}

public enum GitDiffLineKind: Hashable, Sendable {
    case context
    case addition
    case deletion
    case metadata
}

public struct GitDiffLine: Identifiable, Hashable, Sendable {
    public let id: Int
    public let kind: GitDiffLineKind
    public let oldLineNumber: Int?
    public let newLineNumber: Int?
    public let content: String

    public init(
        id: Int,
        kind: GitDiffLineKind,
        oldLineNumber: Int?,
        newLineNumber: Int?,
        content: String
    ) {
        self.id = id
        self.kind = kind
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
        self.content = content
    }
}

public struct GitDiffHunk: Identifiable, Hashable, Sendable {
    public let id: Int
    public let header: String
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int
    public let lines: [GitDiffLine]

    public init(
        id: Int,
        header: String,
        oldStart: Int,
        oldCount: Int,
        newStart: Int,
        newCount: Int,
        lines: [GitDiffLine]
    ) {
        self.id = id
        self.header = header
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.lines = lines
    }
}

public struct GitFileDiff: Hashable, Sendable {
    public let change: GitFileChange
    public let scope: GitDiffScope
    public let hunks: [GitDiffHunk]
    public let message: String?

    public init(
        change: GitFileChange,
        scope: GitDiffScope,
        hunks: [GitDiffHunk],
        message: String?
    ) {
        self.change = change
        self.scope = scope
        self.hunks = hunks
        self.message = message
    }

    public var addedLineCount: Int {
        hunks.reduce(0) { count, hunk in
            count + hunk.lines.count(where: { $0.kind == .addition })
        }
    }

    public var deletedLineCount: Int {
        hunks.reduce(0) { count, hunk in
            count + hunk.lines.count(where: { $0.kind == .deletion })
        }
    }
}

public enum UnifiedDiffParseError: Error, Equatable, Sendable {
    case invalidUTF8
    case malformedHunkHeader(String)
}

public enum UnifiedDiffParser {
    public static func parse(
        _ data: Data,
        change: GitFileChange,
        scope: GitDiffScope
    ) throws -> GitFileDiff {
        guard let text = String(data: data, encoding: .utf8) else {
            throw UnifiedDiffParseError.invalidUTF8
        }

        var rawLines = text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        if rawLines.last == "" {
            rawLines.removeLast()
        }

        var hunks: [GitDiffHunk] = []
        var currentHeader: ParsedHunkHeader?
        var currentLines: [GitDiffLine] = []
        var oldLine = 0
        var newLine = 0
        var lineID = 0
        var message: String?

        func finishHunk() {
            guard let currentHeader else {
                return
            }
            hunks.append(
                GitDiffHunk(
                    id: hunks.count,
                    header: currentHeader.raw,
                    oldStart: currentHeader.oldStart,
                    oldCount: currentHeader.oldCount,
                    newStart: currentHeader.newStart,
                    newCount: currentHeader.newCount,
                    lines: currentLines
                )
            )
        }

        for rawLine in rawLines {
            if rawLine.hasPrefix("@@ ") {
                finishHunk()
                let parsed = try parseHunkHeader(rawLine)
                currentHeader = parsed
                currentLines = []
                oldLine = parsed.oldStart
                newLine = parsed.newStart
                continue
            }

            guard currentHeader != nil else {
                if rawLine.hasPrefix("Binary files ") || rawLine == "GIT binary patch" {
                    message = "Binary diff"
                }
                continue
            }

            let line: GitDiffLine
            if rawLine.hasPrefix("+") {
                line = GitDiffLine(
                    id: lineID,
                    kind: .addition,
                    oldLineNumber: nil,
                    newLineNumber: newLine,
                    content: String(rawLine.dropFirst())
                )
                newLine += 1
            } else if rawLine.hasPrefix("-") {
                line = GitDiffLine(
                    id: lineID,
                    kind: .deletion,
                    oldLineNumber: oldLine,
                    newLineNumber: nil,
                    content: String(rawLine.dropFirst())
                )
                oldLine += 1
            } else if rawLine.hasPrefix(" ") {
                line = GitDiffLine(
                    id: lineID,
                    kind: .context,
                    oldLineNumber: oldLine,
                    newLineNumber: newLine,
                    content: String(rawLine.dropFirst())
                )
                oldLine += 1
                newLine += 1
            } else {
                line = GitDiffLine(
                    id: lineID,
                    kind: .metadata,
                    oldLineNumber: nil,
                    newLineNumber: nil,
                    content: rawLine
                )
            }
            lineID += 1
            currentLines.append(line)
        }

        finishHunk()
        if hunks.isEmpty, message == nil, !data.isEmpty {
            message = "No textual hunks"
        }

        return GitFileDiff(
            change: change,
            scope: scope,
            hunks: hunks,
            message: message
        )
    }

    public static func addedFile(
        data: Data,
        change: GitFileChange,
        maximumTextBytes: Int = 4 * 1_024 * 1_024
    ) -> GitFileDiff {
        guard data.count <= maximumTextBytes else {
            return GitFileDiff(
                change: change,
                scope: .working,
                hunks: [],
                message: "File is too large for the initial text reviewer"
            )
        }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            return GitFileDiff(
                change: change,
                scope: .working,
                hunks: [],
                message: "Binary file"
            )
        }
        guard !text.isEmpty else {
            return GitFileDiff(
                change: change,
                scope: .working,
                hunks: [],
                message: "Empty file"
            )
        }

        var contents = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") {
            contents.removeLast()
        }
        let lines = contents.enumerated().map { index, content in
            GitDiffLine(
                id: index,
                kind: .addition,
                oldLineNumber: nil,
                newLineNumber: index + 1,
                content: content
            )
        }
        let hunk = GitDiffHunk(
            id: 0,
            header: "@@ -0,0 +1,\(lines.count) @@",
            oldStart: 0,
            oldCount: 0,
            newStart: 1,
            newCount: lines.count,
            lines: lines
        )
        return GitFileDiff(
            change: change,
            scope: .working,
            hunks: [hunk],
            message: nil
        )
    }

    private static func parseHunkHeader(_ line: String) throws -> ParsedHunkHeader {
        guard
            let closingRange = line.range(of: " @@", range: line.index(line.startIndex, offsetBy: 3)..<line.endIndex)
        else {
            throw UnifiedDiffParseError.malformedHunkHeader(line)
        }

        let coordinates = line[line.index(line.startIndex, offsetBy: 3)..<closingRange.lowerBound]
            .split(separator: " ")
        guard coordinates.count == 2 else {
            throw UnifiedDiffParseError.malformedHunkHeader(line)
        }

        let oldRange = try parseCoordinate(String(coordinates[0]), prefix: "-", line: line)
        let newRange = try parseCoordinate(String(coordinates[1]), prefix: "+", line: line)
        return ParsedHunkHeader(
            raw: line,
            oldStart: oldRange.start,
            oldCount: oldRange.count,
            newStart: newRange.start,
            newCount: newRange.count
        )
    }

    private static func parseCoordinate(
        _ coordinate: String,
        prefix: Character,
        line: String
    ) throws -> (start: Int, count: Int) {
        guard coordinate.first == prefix else {
            throw UnifiedDiffParseError.malformedHunkHeader(line)
        }
        let values = coordinate.dropFirst().split(separator: ",", maxSplits: 1)
        guard let start = Int(values[0]) else {
            throw UnifiedDiffParseError.malformedHunkHeader(line)
        }
        let count = values.count == 2 ? Int(values[1]) : 1
        guard let count else {
            throw UnifiedDiffParseError.malformedHunkHeader(line)
        }
        return (start, count)
    }
}

private struct ParsedHunkHeader {
    let raw: String
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
}
