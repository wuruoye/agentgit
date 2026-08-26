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

/// Diff 的呈现口径。上下文行数与忽略空白都只是 git 参数，改了要重新取一次。
public enum GitDiffContext: Hashable, Sendable {
    case lines(Int)
    case wholeFile

    public var unifiedArgument: String {
        switch self {
        case let .lines(count): "--unified=\(count)"
        // git 没有“整文件”开关，惯例是给一个大到覆盖任何文件的上下文。
        case .wholeFile: "--unified=1000000"
        }
    }

    public var title: String {
        switch self {
        case let .lines(count): "\(count) Lines"
        case .wholeFile: "Whole File"
        }
    }
}

public struct GitDiffOptions: Hashable, Sendable {
    public var context: GitDiffContext
    public var ignoresWhitespace: Bool

    public init(context: GitDiffContext = .lines(3), ignoresWhitespace: Bool = false) {
        self.context = context
        self.ignoresWhitespace = ignoresWhitespace
    }

    public var arguments: [String] {
        var arguments = [context.unifiedArgument]
        if ignoresWhitespace {
            arguments.append("--ignore-all-space")
        }
        return arguments
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
    /// 与配对行的字符级差异；为空表示整行按行底色处理。
    public let inlineRanges: [GitDiffInlineRange]

    public init(
        id: Int,
        kind: GitDiffLineKind,
        oldLineNumber: Int?,
        newLineNumber: Int?,
        content: String,
        inlineRanges: [GitDiffInlineRange] = []
    ) {
        self.id = id
        self.kind = kind
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
        self.content = content
        self.inlineRanges = inlineRanges
    }

    func withInlineRanges(_ ranges: [GitDiffInlineRange]) -> GitDiffLine {
        GitDiffLine(
            id: id,
            kind: kind,
            oldLineNumber: oldLineNumber,
            newLineNumber: newLineNumber,
            content: content,
            inlineRanges: ranges
        )
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

/// 没有 hunk 时到底发生了什么。UI 要能区分二进制、过大、无改动和不可用。
public enum GitFileDiffState: Hashable, Sendable {
    case textual
    case binary
    case tooLarge(lineCount: Int)
    case unavailable(String)

    public var note: String? {
        switch self {
        case .textual: nil
        case .binary: "Binary file"
        case let .tooLarge(lineCount): "Diff too large to display (\(lineCount) lines)"
        case let .unavailable(reason): reason
        }
    }
}

public struct GitFileDiff: Hashable, Sendable {
    public let change: GitFileChange
    public let scope: GitDiffScope
    public let hunks: [GitDiffHunk]
    public let state: GitFileDiffState
    /// 存储而非每次现算：文件头每次重绘都要读，现算等于把全文再走一遍。
    public let addedLineCount: Int
    public let deletedLineCount: Int

    public init(
        change: GitFileChange,
        scope: GitDiffScope,
        hunks: [GitDiffHunk],
        state: GitFileDiffState,
        addedLineCount: Int,
        deletedLineCount: Int
    ) {
        self.change = change
        self.scope = scope
        self.hunks = hunks
        self.state = state
        self.addedLineCount = addedLineCount
        self.deletedLineCount = deletedLineCount
    }

    public init(
        change: GitFileChange,
        scope: GitDiffScope,
        hunks: [GitDiffHunk],
        state: GitFileDiffState
    ) {
        self.init(
            change: change,
            scope: scope,
            hunks: hunks,
            state: state,
            addedLineCount: hunks.reduce(0) { count, hunk in
                count + hunk.lines.count(where: { $0.kind == .addition })
            },
            deletedLineCount: hunks.reduce(0) { count, hunk in
                count + hunk.lines.count(where: { $0.kind == .deletion })
            }
        )
    }
}

public enum UnifiedDiffParseError: Error, Equatable, Sendable {
    case invalidUTF8
    case malformedHunkHeader(String)
}

public enum UnifiedDiffParser {
    /// 单文件行数上限。超过就只报状态，不再构造行对象。
    public static let maximumRenderedLines = 50_000

    public static func parseFiles(
        _ data: Data,
        changes: [GitFileChange],
        scope: GitDiffScope
    ) throws -> [GitFileDiff] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw UnifiedDiffParseError.invalidUTF8
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var chunks: [[String]] = []
        var currentChunk: [String] = []

        for line in lines {
            if line.hasPrefix("diff --git "), !currentChunk.isEmpty {
                chunks.append(currentChunk)
                currentChunk = []
            }
            if !currentChunk.isEmpty || line.hasPrefix("diff --git ") {
                currentChunk.append(line)
            }
        }
        if !currentChunk.isEmpty {
            chunks.append(currentChunk)
        }

        var parsedByChangeID: [GitFileChange.ID: GitFileDiff] = [:]
        for chunk in chunks {
            guard let header = chunk.first,
                  let change = changes.first(where: { header.hasSuffix(" b/\($0.path)") }) else {
                continue
            }
            let patch = chunk.joined(separator: "\n")
            parsedByChangeID[change.id] = try parse(
                Data(patch.utf8),
                change: change,
                scope: scope
            )
        }

        return changes.map { change in
            parsedByChangeID[change.id] ?? GitFileDiff(
                change: change,
                scope: scope,
                hunks: [],
                state: .textual
            )
        }
    }

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
        var state = GitFileDiffState.textual

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
                    lines: InlineDiffCalculator.annotate(currentLines)
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
                    state = .binary
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

        // 超大单文件不建行数组：真正的代价在解析和内存，不在表格渲染。
        let lineCount = hunks.reduce(0) { $0 + $1.lines.count }
        if state == .textual, lineCount > maximumRenderedLines {
            return GitFileDiff(
                change: change,
                scope: scope,
                hunks: [],
                state: .tooLarge(lineCount: lineCount),
                addedLineCount: hunks.reduce(0) { count, hunk in
                    count + hunk.lines.count(where: { $0.kind == .addition })
                },
                deletedLineCount: hunks.reduce(0) { count, hunk in
                    count + hunk.lines.count(where: { $0.kind == .deletion })
                }
            )
        }

        return GitFileDiff(
            change: change,
            scope: scope,
            hunks: hunks,
            state: state
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
                state: .unavailable("File is too large for the initial text reviewer")
            )
        }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            return GitFileDiff(
                change: change,
                scope: .working,
                hunks: [],
                state: .binary
            )
        }
        guard !text.isEmpty else {
            return GitFileDiff(
                change: change,
                scope: .working,
                hunks: [],
                state: .unavailable("Empty file")
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
            state: .textual
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
