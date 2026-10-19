import Foundation

/// 从已有的完整 diff 推出忽略空白后的 diff，切换“忽略空白”时不用再跑一次 git。
public enum GitDiffWhitespaceFilter {
    /// 每个 hunk 按 `git diff --ignore-all-space` 的比较规则和 git 的对齐算法重排，只差空白的行成为上下文，再按上下文行数重切 hunk。
    /// `recomputesSectionHeadings` 为 true 时按 git 默认函数名规则重算拆出来的 hunk 标题。
    ///
    /// 只有 hunk 内的内容时，结果可能和 git -w 不同：git 按整份文件统计行的出现次数（只含空白的行和空行算同一种），
    /// 滑动改动后也可能用到 hunk 外的上下文，所以没有只差空白改动的文件也可能变。
    /// `wholeFileSource` 是同一份内容的整文件 diff，有它就从它重算，结果与 git -w 一致；
    /// 改动行沿用 `diff` 里同一行的 id（部分暂存按这些 id 生成补丁）。`recomputesSectionHeadings` 为 false 时，
    /// 整文件按默认规则算出的标题与 `diff` 一致才重算，否则沿用 `diff` 里对应 hunk 的标题。
    public static func ignoringWhitespace(
        _ diff: GitFileDiff,
        context: GitDiffContext,
        recomputesSectionHeadings: Bool = false,
        wholeFileSource: GitFileDiff? = nil
    ) -> GitFileDiff {
        if let source = wholeFileSource, isWholeFileSource(source, of: diff) {
            // 不确定是否按默认规则找标题时，先按默认规则从整文件裁一次：与 git 给 `diff` 的标题全部相同就照默认规则重算。
            let recomputes = recomputesSectionHeadings || GitDiffReshaper.reshape(
                source,
                context: context,
                mergesWhitespace: false,
                renumbersLines: true,
                recomputesSectionHeadings: true
            ).hunks.map(\.header) == diff.hunks.map(\.header)
            let realigned = GitDiffReshaper.reshape(
                source,
                context: context,
                mergesWhitespace: true,
                renumbersLines: false,
                recomputesSectionHeadings: recomputes
            )
            return GitDiffReshaper.adoptingLines(of: diff, in: realigned, adoptsSectionHeadings: !recomputes)
        }
        return GitDiffReshaper.reshape(
            diff,
            context: context,
            mergesWhitespace: true,
            renumbersLines: false,
            recomputesSectionHeadings: recomputesSectionHeadings
        )
    }

    /// `source` 是 `diff` 同一份内容的整文件 diff：同一文件、单个从首行开始的 hunk、增删行数相同。
    public static func isWholeFileSource(_ source: GitFileDiff, of diff: GitFileDiff) -> Bool {
        guard source.state == .textual, diff.state == .textual,
              source.change.id == diff.change.id, source.scope == diff.scope,
              source.addedLineCount == diff.addedLineCount,
              source.deletedLineCount == diff.deletedLineCount,
              source.hunks.count == 1, let hunk = source.hunks.first else {
            return false
        }
        return hunk.oldStart <= 1 && hunk.newStart <= 1
    }
}

public enum GitDiffContextTrimmer {
    /// 从上下文更多的 diff（`-U<m>` 或整文件）裁出 `context` 行上下文的结果，hunk 拆分与 `git diff -U<n>` 一致。
    public static func trimming(
        _ diff: GitFileDiff,
        to context: GitDiffContext,
        recomputesSectionHeadings: Bool
    ) -> GitFileDiff {
        GitDiffReshaper.reshape(
            diff,
            context: context,
            mergesWhitespace: false,
            renumbersLines: true,
            recomputesSectionHeadings: recomputesSectionHeadings
        )
    }
}

/// 两个公共入口共用的流程：分组 →（可选）忽略空白重新对齐 → 按上下文行数重切 → 生成 hunk。
private enum GitDiffReshaper {
    /// git `struct func_line` 的缓冲区大小，标题最多取这么多字节。
    private static let maximumSectionHeadingBytes = 80

    /// `renumbersLines` 为 true 时 line.id 按输出顺序从 0 重排，与直接解析 git 输出一致；
    /// 为 false 时保留原 id，合并出来的上下文行从原最大 id + 1 起编号。
    static func reshape(
        _ diff: GitFileDiff,
        context: GitDiffContext,
        mergesWhitespace: Bool,
        renumbersLines: Bool,
        recomputesSectionHeadings: Bool
    ) -> GitFileDiff {
        guard diff.state == .textual, !diff.hunks.isEmpty else {
            return diff
        }

        let contextLimit: Int?
        switch context {
        case let .lines(count):
            // 夹到不会在 2N 上溢出的范围；再大也等同整文件。
            contextLimit = min(max(0, count), Int.max / 4)
        case .wholeFile:
            contextLimit = nil
        }

        var nextMergedLineID = 0
        if mergesWhitespace {
            for hunk in diff.hunks {
                for line in hunk.lines {
                    nextMergedLineID = max(nextMergedLineID, line.id + 1)
                }
            }
        }

        var keys = WhitespaceInsensitiveKeys()
        var changed = false
        var plans: [(hunk: GitDiffHunk, entries: [Entry], ranges: [ClosedRange<Int>])] = []
        plans.reserveCapacity(diff.hunks.count)

        for hunk in diff.hunks {
            var entries = makeEntries(hunk.lines)
            if mergesWhitespace,
               let realigned = realignIgnoringWhitespace(entries, keys: &keys, nextLineID: &nextMergedLineID) {
                entries = realigned
                changed = true
            }
            let ranges = keptRanges(in: entries, contextLimit: contextLimit)
            if ranges.count != 1 || ranges[0] != 0...(entries.count - 1) {
                changed = true
            }
            plans.append((hunk, entries, ranges))
        }

        // 没有行被合并、也没有 hunk 被裁剪拆分时返回原值，renderID 不变。
        guard changed else {
            return diff
        }

        var nextOutputLineID = 0
        var hunks: [GitDiffHunk] = []
        for plan in plans {
            hunks.append(
                contentsOf: makeHunks(
                    from: plan.entries,
                    ranges: plan.ranges,
                    original: plan.hunk,
                    firstHunkID: hunks.count,
                    renumbersLines: renumbersLines,
                    nextOutputLineID: &nextOutputLineID,
                    recomputesSectionHeadings: recomputesSectionHeadings
                )
            )
        }

        return GitFileDiff(
            change: diff.change,
            scope: diff.scope,
            hunks: hunks,
            state: .textual
        )
    }

    // MARK: - 行分组

    /// 一行正文加上紧跟其后的 metadata 行（`\ No newline at end of file`），移动时作为整体。
    private struct Entry {
        var line: GitDiffLine
        var trailing: [GitDiffLine] = []
        /// 合并出来的上下文行显示新侧内容，找函数名标题时要用这里记下的旧侧内容。
        var oldContent: String?

        /// 不在 hunk 开头之外出现的孤立 metadata 也算改动，原样保留。
        var isChange: Bool {
            line.kind != .context
        }
    }

    private static func makeEntries(_ lines: [GitDiffLine]) -> [Entry] {
        var entries: [Entry] = []
        entries.reserveCapacity(lines.count)
        for line in lines {
            if line.kind == .metadata, !entries.isEmpty {
                entries[entries.count - 1].trailing.append(line)
            } else {
                entries.append(Entry(line: line))
            }
        }
        return entries
    }

    // MARK: - 忽略空白重新对齐

    /// 整个 hunk 按去空白的键重跑 git 的对齐。原 diff 里凑巧相同的行会把一次缩进改动切成几块，
    /// 只在块内合并会漏掉跨块的对应行，所以两侧的上下文行也一起参与。结果与原 hunk 相同时返回 nil。
    private static func realignIgnoringWhitespace(
        _ entries: [Entry],
        keys: inout WhitespaceInsensitiveKeys,
        nextLineID: inout Int
    ) -> [Entry]? {
        var oldSide: [Int] = []
        var newSide: [Int] = []
        for (index, entry) in entries.enumerated() {
            switch entry.line.kind {
            case .context:
                oldSide.append(index)
                newSide.append(index)
            case .deletion: oldSide.append(index)
            case .addition: newSide.append(index)
            case .metadata: return nil
            }
        }
        // 一侧没有任何行（新建或删除整个文件）时没有可对齐的内容。
        guard !oldSide.isEmpty, !newSide.isEmpty, entries.contains(where: \.isChange) else {
            return nil
        }

        // 缺行尾换行在 git -w 下也算空白，带 metadata 的行照常参与比较。
        func xdiffLines(_ side: [Int]) -> [GitXdiff.Line] {
            side.map { index in
                let content = entries[index].line.content
                return GitXdiff.Line(key: keys.key(for: content), indent: GitXdiff.indent(of: content))
            }
        }
        guard let changed = GitXdiff.changedLines(old: xdiffLines(oldSide), new: xdiffLines(newSide)) else {
            return nil
        }

        var result: [Entry] = []
        result.reserveCapacity(entries.count)
        var createdLines = false

        // 新建的行连同它的 metadata 另起 id，避免和原 diff 里的行撞号。
        func makeEntry(
            from source: Entry,
            kind: GitDiffLineKind,
            oldLineNumber: Int?,
            newLineNumber: Int?,
            oldContent: String? = nil
        ) -> Entry {
            func fresh(_ line: GitDiffLine, kind: GitDiffLineKind, old: Int?, new: Int?) -> GitDiffLine {
                defer { nextLineID += 1 }
                return GitDiffLine(
                    id: nextLineID, kind: kind, oldLineNumber: old, newLineNumber: new, content: line.content
                )
            }
            createdLines = true
            return Entry(
                line: fresh(source.line, kind: kind, old: oldLineNumber, new: newLineNumber),
                trailing: source.trailing.map { fresh($0, kind: .metadata, old: nil, new: nil) },
                oldContent: oldContent
            )
        }

        var oldCursor = 0
        var newCursor = 0
        while oldCursor < oldSide.count || newCursor < newSide.count {
            if oldCursor < oldSide.count, newCursor < newSide.count,
               !changed.old[oldCursor], !changed.new[newCursor] {
                let oldIndex = oldSide[oldCursor]
                let newIndex = newSide[newCursor]
                if oldIndex == newIndex {
                    result.append(entries[newIndex])
                } else {
                    // git -w 的上下文行取新侧内容和新侧的行尾标记。
                    let deletion = entries[oldIndex].line
                    result.append(makeEntry(
                        from: entries[newIndex], kind: .context,
                        oldLineNumber: deletion.oldLineNumber,
                        newLineNumber: entries[newIndex].line.newLineNumber,
                        oldContent: deletion.content
                    ))
                }
                oldCursor += 1
                newCursor += 1
                continue
            }

            // 与 git 输出一致：每组改动先列删除再列新增。
            let deletionStart = oldCursor
            while oldCursor < oldSide.count, changed.old[oldCursor] {
                oldCursor += 1
            }
            let additionStart = newCursor
            while newCursor < newSide.count, changed.new[newCursor] {
                newCursor += 1
            }
            guard oldCursor > deletionStart || newCursor > additionStart else {
                return nil
            }
            for index in oldSide[deletionStart..<oldCursor] {
                let entry = entries[index]
                result.append(entry.line.kind == .deletion ? entry : makeEntry(
                    from: entry, kind: .deletion, oldLineNumber: entry.line.oldLineNumber, newLineNumber: nil
                ))
            }
            for index in newSide[additionStart..<newCursor] {
                let entry = entries[index]
                result.append(entry.line.kind == .addition ? entry : makeEntry(
                    from: entry, kind: .addition, oldLineNumber: nil, newLineNumber: entry.line.newLineNumber
                ))
            }
        }
        return createdLines ? result : nil
    }

    // MARK: - 重切 hunk

    /// 每段从第一处改动前 N 行到最后一处改动后 N 行；改动之间的上下文超过 2N 行就断开。不跨出原 hunk。
    private static func keptRanges(in entries: [Entry], contextLimit: Int?) -> [ClosedRange<Int>] {
        var ranges: [ClosedRange<Int>] = []
        var groupStart: Int?
        var groupEnd = 0

        func closeGroup() {
            guard let start = groupStart else {
                return
            }
            if let limit = contextLimit {
                ranges.append(max(0, start - limit)...min(entries.count - 1, groupEnd + limit))
            } else {
                ranges.append(0...(entries.count - 1))
            }
        }

        for index in entries.indices where entries[index].isChange {
            if groupStart == nil {
                groupStart = index
            } else if let limit = contextLimit, index - groupEnd - 1 > 2 * limit {
                closeGroup()
                groupStart = index
            }
            groupEnd = index
        }
        closeGroup()
        return ranges
    }

    private static func makeHunks(
        from entries: [Entry],
        ranges: [ClosedRange<Int>],
        original: GitDiffHunk,
        firstHunkID: Int,
        renumbersLines: Bool,
        nextOutputLineID: inout Int,
        recomputesSectionHeadings: Bool
    ) -> [GitDiffHunk] {
        // count 为 0 时 git 把 start 写成“前一行”，这里先记下一行的行号，再按需减一。
        var nextOld = original.oldCount > 0 ? original.oldStart : original.oldStart + 1
        var nextNew = original.newCount > 0 ? original.newStart : original.newStart + 1
        var cursor = 0
        // 源 hunk 的标题就是 git 在源 hunk 起点之前找到的结果；源 hunk 内找不到时沿用它。
        var heading = SectionHeading(
            text: sourceSectionHeadingText(original.header),
            parsed: original.sectionHeading
        )
        var scannedFloor = -1
        var hunks: [GitDiffHunk] = []
        hunks.reserveCapacity(ranges.count)

        func advance(past entry: Entry) {
            if let number = entry.line.oldLineNumber { nextOld = number + 1 }
            if let number = entry.line.newLineNumber { nextNew = number + 1 }
        }

        func output(_ line: GitDiffLine) -> GitDiffLine {
            guard renumbersLines else {
                return line.withInlineRanges([])
            }
            defer { nextOutputLineID += 1 }
            return GitDiffLine(
                id: nextOutputLineID,
                kind: line.kind,
                oldLineNumber: line.oldLineNumber,
                newLineNumber: line.newLineNumber,
                content: line.content
            )
        }

        for range in ranges {
            while cursor < range.lowerBound {
                advance(past: entries[cursor])
                cursor += 1
            }

            // 与 git `get_func_line` 一致：从新 hunk 前一行往回找，只找到上一个 hunk 的起点为止，
            // 找不到就沿用上一个标题，整体只扫一遍。
            if recomputesSectionHeadings {
                var index = range.lowerBound - 1
                while index > scannedFloor {
                    if let found = functionHeading(of: entries[index]) {
                        heading = found
                        break
                    }
                    index -= 1
                }
                scannedFloor = range.lowerBound - 1
            }

            let fallbackOldStart = nextOld - 1
            let fallbackNewStart = nextNew - 1
            var firstOld: Int?
            var firstNew: Int?
            var oldCount = 0
            var newCount = 0
            var lines: [GitDiffLine] = []
            lines.reserveCapacity(range.count)
            for entry in entries[range] {
                if let number = entry.line.oldLineNumber {
                    if firstOld == nil { firstOld = number }
                    oldCount += 1
                }
                if let number = entry.line.newLineNumber {
                    if firstNew == nil { firstNew = number }
                    newCount += 1
                }
                lines.append(output(entry.line))
                for metadata in entry.trailing {
                    lines.append(output(metadata))
                }
                advance(past: entry)
            }
            cursor = range.upperBound + 1

            let oldStart = firstOld ?? fallbackOldStart
            let newStart = firstNew ?? fallbackNewStart
            hunks.append(
                GitDiffHunk(
                    id: firstHunkID + hunks.count,
                    header: hunkHeader(
                        oldStart: oldStart,
                        oldCount: oldCount,
                        newStart: newStart,
                        newCount: newCount,
                        sectionHeading: heading.text
                    ),
                    sectionHeading: heading.parsed,
                    oldStart: oldStart,
                    oldCount: oldCount,
                    newStart: newStart,
                    newCount: newCount,
                    lines: InlineDiffCalculator.annotate(lines)
                )
            )
        }
        return hunks
    }

    /// 与 git 的 `xdl_emit_hunk_hdr` 一致：count 为 1 时省略，标题前空一格。
    private static func hunkHeader(
        oldStart: Int,
        oldCount: Int,
        newStart: Int,
        newCount: Int,
        sectionHeading: String?
    ) -> String {
        var header = "@@ -\(oldStart)"
        if oldCount != 1 { header += ",\(oldCount)" }
        header += " +\(newStart)"
        if newCount != 1 { header += ",\(newCount)" }
        header += " @@"
        if let sectionHeading { header += " \(sectionHeading)" }
        return header
    }

    // MARK: - 函数名标题

    /// `text` 是 header 里 `@@` 之后的原文，`parsed` 是解析器去掉首尾空白后的 sectionHeading。
    private struct SectionHeading {
        var text: String?
        var parsed: String?
    }

    /// 取 header 里 ` @@ ` 之后的原文，保证沿用时 header 字符串和 git 输出逐字相同。
    private static func sourceSectionHeadingText(_ header: String) -> String? {
        guard header.hasPrefix("@@ "),
              let closing = header.range(
                  of: " @@",
                  range: header.index(header.startIndex, offsetBy: 3)..<header.endIndex
              ) else {
            return nil
        }
        var text = header[closing.upperBound...]
        if text.first == " " {
            text = text.dropFirst()
        }
        return text.isEmpty ? nil : String(text)
    }

    /// git 默认规则（xdiff `def_ff`）：旧侧行首字节是 ASCII 字母、`_` 或 `$` 就是标题，
    /// 取前 80 字节再去掉末尾空白。行尾换行在 80 字节内时总会被当空白去掉，所以不必拼上。
    private static func functionHeading(of entry: Entry) -> SectionHeading? {
        guard entry.line.kind == .context || entry.line.kind == .deletion else {
            return nil
        }
        let content = entry.oldContent ?? entry.line.content
        guard let first = content.utf8.first,
              (first >= 0x41 && first <= 0x5A) || (first >= 0x61 && first <= 0x7A)
                || first == UInt8(ascii: "_") || first == UInt8(ascii: "$") else {
            return nil
        }
        var bytes = Array(content.utf8.prefix(maximumSectionHeadingBytes))
        while let last = bytes.last, isGitSpace(last) {
            bytes.removeLast()
        }
        // 截断落在多字节字符中间时，git 输出的标题不带这半个字符；先去空白再丢，前面的空格保留。
        if let leadIndex = bytes.lastIndex(where: { $0 & 0xC0 != 0x80 }) {
            let lead = bytes[leadIndex]
            let length = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
            if bytes.count - leadIndex < length {
                bytes.removeSubrange(leadIndex...)
            }
        }
        let text = String(decoding: bytes, as: UTF8.self)
        let parsed = text.trimmingCharacters(in: .whitespaces)
        return SectionHeading(text: text, parsed: parsed.isEmpty ? nil : parsed)
    }
}

// MARK: - 整文件来源

extension GitDiffReshaper {
    /// 从整文件 diff 重算出的结果换回界面已有 diff 的行 id：同一删除行、新增行、上下文行沿用原 id，
    /// 其余行从原最大 id + 1 起编号。不重算标题时，每个 hunk 取 `displayed` 里起点不晚于它的最后一个 hunk 的标题。
    static func adoptingLines(
        of displayed: GitFileDiff,
        in realigned: GitFileDiff,
        adoptsSectionHeadings: Bool
    ) -> GitFileDiff {
        struct ContextLine: Hashable {
            let old: Int
            let new: Int
        }
        var deletionIDs: [Int: Int] = [:]
        var additionIDs: [Int: Int] = [:]
        var contextIDs: [ContextLine: Int] = [:]
        var nextID = 0
        for line in displayed.hunks.lazy.flatMap(\.lines) {
            nextID = max(nextID, line.id + 1)
            switch (line.kind, line.oldLineNumber, line.newLineNumber) {
            case let (.deletion, old?, _): deletionIDs[old] = line.id
            case let (.addition, _, new?): additionIDs[new] = line.id
            case let (.context, old?, new?): contextIDs[ContextLine(old: old, new: new)] = line.id
            default: break
            }
        }

        let hunks = realigned.hunks.enumerated().map { index, hunk in
            let lines = hunk.lines.map { line in
                let adoptedID: Int? = switch (line.kind, line.oldLineNumber, line.newLineNumber) {
                case let (.deletion, old?, _): deletionIDs[old]
                case let (.addition, _, new?): additionIDs[new]
                case let (.context, old?, new?): contextIDs[ContextLine(old: old, new: new)]
                default: nil
                }
                let id: Int
                if let adoptedID {
                    id = adoptedID
                } else {
                    id = nextID
                    nextID += 1
                }
                return GitDiffLine(
                    id: id,
                    kind: line.kind,
                    oldLineNumber: line.oldLineNumber,
                    newLineNumber: line.newLineNumber,
                    content: line.content,
                    inlineRanges: line.inlineRanges
                )
            }
            var header = hunk.header
            var sectionHeading = hunk.sectionHeading
            if adoptsSectionHeadings {
                let source = displayed.hunks.last { $0.oldStart <= hunk.oldStart }
                header = hunkHeader(
                    oldStart: hunk.oldStart,
                    oldCount: hunk.oldCount,
                    newStart: hunk.newStart,
                    newCount: hunk.newCount,
                    sectionHeading: source.flatMap { sourceSectionHeadingText($0.header) }
                )
                sectionHeading = source?.sectionHeading
            }
            return GitDiffHunk(
                id: index,
                header: header,
                sectionHeading: sectionHeading,
                oldStart: hunk.oldStart,
                oldCount: hunk.oldCount,
                newStart: hunk.newStart,
                newCount: hunk.newCount,
                lines: lines
            )
        }
        return GitFileDiff(change: displayed.change, scope: displayed.scope, hunks: hunks, state: realigned.state)
    }
}

/// git 的 `isspace` 只认空格、`\t`、`\n`、`\r`（`\v`、`\f` 不算）。
private func isGitSpace(_ byte: UInt8) -> Bool {
    byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
}

/// 去掉空白后的行内容映射成整数，对齐时只比整数。
private struct WhitespaceInsensitiveKeys {
    private var keysByContent: [[UInt8]: Int] = [:]

    mutating func key(for content: String) -> Int {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(content.utf8.count)
        for byte in content.utf8 where !isGitSpace(byte) {
            bytes.append(byte)
        }
        if let key = keysByContent[bytes] {
            return key
        }
        let key = keysByContent.count
        keysByContent[bytes] = key
        return key
    }
}
