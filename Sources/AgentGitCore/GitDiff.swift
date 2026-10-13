import Foundation

public enum GitDiffScope: String, CaseIterable, Identifiable, Hashable, Codable, Sendable {
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
public enum GitDiffContext: Hashable, Codable, Sendable {
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

public struct GitDiffOptions: Hashable, Codable, Sendable {
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

public enum GitDiffLineKind: Hashable, Codable, Sendable {
    case context
    case addition
    case deletion
    case metadata
}

public struct GitDiffLine: Identifiable, Hashable, Codable, Sendable {
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

public struct GitDiffHunk: Identifiable, Hashable, Codable, Sendable {
    public let id: Int
    public let header: String
    public let sectionHeading: String?
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int
    public let lines: [GitDiffLine]

    public init(
        id: Int,
        header: String,
        sectionHeading: String? = nil,
        oldStart: Int,
        oldCount: Int,
        newStart: Int,
        newCount: Int,
        lines: [GitDiffLine]
    ) {
        self.id = id
        self.header = header
        self.sectionHeading = sectionHeading
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.lines = lines
    }
}

/// 没有 hunk 时到底发生了什么。UI 要能区分二进制、过大、无改动和不可用。
public enum GitFileDiffState: Hashable, Codable, Sendable {
    case textual
    case metadata(String)
    case binary
    case tooLarge(lineCount: Int)
    case unavailable(String)

    public var note: String? {
        switch self {
        case .textual: nil
        case let .metadata(summary): summary
        case .binary: "Binary file"
        case let .tooLarge(lineCount): "Diff too large to display (\(lineCount) lines)"
        case let .unavailable(reason): reason
        }
    }
}

public struct GitFileDiff: Hashable, Codable, Sendable {
    public private(set) var change: GitFileChange
    public let scope: GitDiffScope
    public let hunks: [GitDiffHunk]
    public let state: GitFileDiffState
    public let renderID: UInt64
    /// 存储而非每次现算：文件头每次重绘都要读，现算等于把全文再走一遍。
    public let addedLineCount: Int
    public let deletedLineCount: Int
    public var sourceIdentity: GitPendingDiffIdentity?

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
        sourceIdentity = nil
        renderID = gitDiffRenderID(
            hunks: hunks,
            state: state,
            addedLineCount: addedLineCount,
            deletedLineCount: deletedLineCount
        )
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

    public func withSourceIdentity(_ identity: GitPendingDiffIdentity?) -> GitFileDiff {
        var diff = self
        diff.sourceIdentity = identity
        return diff
    }

    public func withChange(_ change: GitFileChange) -> GitFileDiff {
        var diff = self
        diff.change = change
        return diff
    }
}

private func gitDiffRenderID(
    hunks: [GitDiffHunk],
    state: GitFileDiffState,
    addedLineCount: Int,
    deletedLineCount: Int
) -> UInt64 {
    var fingerprint = GitDiffRenderFingerprint()
    switch state {
    case .textual:
        fingerprint.combine("textual")
    case let .metadata(summary):
        fingerprint.combine("metadata")
        fingerprint.combine(summary)
    case .binary:
        fingerprint.combine("binary")
    case let .tooLarge(lineCount):
        fingerprint.combine("too-large")
        fingerprint.combine(lineCount)
    case let .unavailable(reason):
        fingerprint.combine("unavailable")
        fingerprint.combine(reason)
    }
    fingerprint.combine(addedLineCount)
    fingerprint.combine(deletedLineCount)
    for hunk in hunks {
        fingerprint.combine(hunk.id)
        fingerprint.combine(hunk.header)
        fingerprint.combine(hunk.sectionHeading)
        fingerprint.combine(hunk.oldStart)
        fingerprint.combine(hunk.oldCount)
        fingerprint.combine(hunk.newStart)
        fingerprint.combine(hunk.newCount)
        for line in hunk.lines {
            fingerprint.combine(line.id)
            switch line.kind {
            case .context: fingerprint.combine(0)
            case .addition: fingerprint.combine(1)
            case .deletion: fingerprint.combine(2)
            case .metadata: fingerprint.combine(3)
            }
            fingerprint.combine(line.oldLineNumber)
            fingerprint.combine(line.newLineNumber)
            fingerprint.combine(line.content)
            for range in line.inlineRanges {
                fingerprint.combine(range.location)
                fingerprint.combine(range.length)
            }
        }
    }
    return fingerprint.value
}

private struct GitDiffRenderFingerprint {
    private(set) var value: UInt64 = 14_695_981_039_346_656_037

    mutating func combine(_ string: String) {
        for byte in string.utf8 {
            combineByte(byte)
        }
        combineByte(0xFF)
    }

    mutating func combine(_ string: String?) {
        guard let string else {
            combineByte(0xFE)
            return
        }
        combineByte(0x01)
        combine(string)
    }

    mutating func combine(_ integer: Int) {
        var bytes = UInt64(bitPattern: Int64(integer)).littleEndian
        withUnsafeBytes(of: &bytes) { buffer in
            for byte in buffer {
                combineByte(byte)
            }
        }
        combineByte(0xFD)
    }

    mutating func combine(_ integer: Int?) {
        guard let integer else {
            combineByte(0xFC)
            return
        }
        combineByte(0x01)
        combine(integer)
    }

    private mutating func combineByte(_ byte: UInt8) {
        value ^= UInt64(byte)
        value &*= 1_099_511_628_211
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
        try Task.checkCancellation()
        guard let text = String(data: data, encoding: .utf8) else {
            throw UnifiedDiffParseError.invalidUTF8
        }

        var changesByHeader: [String: GitFileChange] = [:]
        for change in changes {
            for oldPath in [change.path, change.originalPath].compactMap({ $0 }) {
                let header = "diff --git a/\(oldPath) b/\(change.path)"
                if changesByHeader[header] == nil { changesByHeader[header] = change }
            }
        }
        var currentChunk: [String] = []
        var currentChange: GitFileChange?
        var currentLineCount = 0
        var parsedByChangeID: [GitFileChange.ID: GitFileDiff] = [:]

        func finishCurrentChunk() throws {
            guard let change = currentChange else {
                currentChunk.removeAll(keepingCapacity: true)
                return
            }
            let outputLineCount = max(0, currentLineCount - 1)
            if currentChunk.last == "" {
                currentChunk.removeLast()
            }
            if outputLineCount > maximumRenderedLines {
                parsedByChangeID[change.id] = GitFileDiff(
                    change: change,
                    scope: scope,
                    hunks: [],
                    state: .tooLarge(lineCount: outputLineCount),
                    addedLineCount: 0,
                    deletedLineCount: 0
                )
            } else {
                parsedByChangeID[change.id] = try parseRawLines(
                    currentChunk,
                    change: change,
                    scope: scope
                )
            }
            currentChunk.removeAll(keepingCapacity: true)
        }

        func consume(_ line: Substring) throws {
            if line.hasPrefix("diff --git ") {
                try finishCurrentChunk()
                let header = String(line)
                currentChange = changesByHeader[header] ?? changes.first(where: {
                    header.hasSuffix(" b/\($0.path)")
                })
                currentLineCount = 0
            }
            guard currentChange != nil else { return }
            currentLineCount += 1
            if currentLineCount <= maximumRenderedLines + 1 {
                currentChunk.append(String(line))
            } else if currentLineCount == maximumRenderedLines + 2 {
                currentChunk.removeAll(keepingCapacity: false)
            }
        }

        let bytes = text.utf8
        var start = bytes.startIndex
        var lineIndex = 0
        while start < bytes.endIndex {
            if lineIndex.isMultiple(of: 256) { try Task.checkCancellation() }
            let end = bytes[start...].firstIndex(of: 0x0A) ?? bytes.endIndex
            try consume(text[start..<end])
            start = end == bytes.endIndex ? end : bytes.index(after: end)
            lineIndex += 1
        }
        if bytes.last == 0x0A { try consume(text[text.endIndex...]) }
        try finishCurrentChunk()

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
        try parseContents(data, change: change, scope: scope)
    }

    public static func parseBounded(
        _ data: Data,
        change: GitFileChange,
        scope: GitDiffScope
    ) throws -> GitFileDiff {
        try Task.checkCancellation()
        let outputLineCount = data.count(where: { $0 == 0x0A })
        try Task.checkCancellation()
        guard outputLineCount <= maximumRenderedLines else {
            return GitFileDiff(
                change: change,
                scope: scope,
                hunks: [],
                state: .tooLarge(lineCount: outputLineCount),
                addedLineCount: 0,
                deletedLineCount: 0
            )
        }
        return try parseContents(data, change: change, scope: scope)
    }

    private static func parseContents(
        _ data: Data,
        change: GitFileChange,
        scope: GitDiffScope
    ) throws -> GitFileDiff {
        try Task.checkCancellation()
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

        return try parseRawLines(
            rawLines,
            change: change,
            scope: scope
        )
    }

    private static func parseRawLines(
        _ rawLines: [String],
        change: GitFileChange,
        scope: GitDiffScope
    ) throws -> GitFileDiff {
        var hunks: [GitDiffHunk] = []
        var currentHeader: ParsedHunkHeader?
        var currentLines: [GitDiffLine] = []
        var oldLine = 0
        var newLine = 0
        var lineID = 0
        var state = GitFileDiffState.textual
        var metadataLines: [String] = []

        func finishHunk() {
            guard let currentHeader else {
                return
            }
            hunks.append(
                GitDiffHunk(
                    id: hunks.count,
                    header: currentHeader.raw,
                    sectionHeading: currentHeader.sectionHeading,
                    oldStart: currentHeader.oldStart,
                    oldCount: currentHeader.oldCount,
                    newStart: currentHeader.newStart,
                    newCount: currentHeader.newCount,
                    lines: InlineDiffCalculator.annotate(currentLines)
                )
            )
        }

        for (rawIndex, rawLine) in rawLines.enumerated() {
            if rawIndex.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            if rawLine.hasPrefix("@@ ") {
                finishHunk()
                try Task.checkCancellation()
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
                } else if isReviewableMetadataLine(rawLine) {
                    metadataLines.append(rawLine)
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
        try Task.checkCancellation()

        if state == .textual, hunks.isEmpty, !metadataLines.isEmpty {
            state = .metadata(metadataLines.joined(separator: " · "))
        }

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

    private static func isReviewableMetadataLine(_ line: String) -> Bool {
        [
            "old mode ",
            "new mode ",
            "new file mode ",
            "deleted file mode ",
            "similarity index ",
            "dissimilarity index ",
            "rename from ",
            "rename to ",
            "copy from ",
            "copy to "
        ].contains { line.hasPrefix($0) }
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
        var lines = contents.enumerated().map { index, content in
            GitDiffLine(
                id: index,
                kind: .addition,
                oldLineNumber: nil,
                newLineNumber: index + 1,
                content: content
            )
        }
        if !text.hasSuffix("\n") {
            lines.append(
                GitDiffLine(
                    id: lines.count,
                    kind: .metadata,
                    oldLineNumber: nil,
                    newLineNumber: nil,
                    content: "\\ No newline at end of file"
                )
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
        let heading = line[closingRange.upperBound...]
            .trimmingCharacters(in: .whitespaces)
        return ParsedHunkHeader(
            raw: line,
            sectionHeading: heading.isEmpty ? nil : heading,
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
    let sectionHeading: String?
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
}
