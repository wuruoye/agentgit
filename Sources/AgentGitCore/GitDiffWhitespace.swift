import Foundation

/// 从已有的完整 diff 推出忽略空白后的 diff，切换“忽略空白”时不用再跑一次 git。
public enum GitDiffWhitespaceFilter {
    /// 按 `git diff --ignore-all-space` 的比较规则，把只差空白的删除/新增行并成上下文，再按上下文行数重切 hunk。
    /// `recomputesSectionHeadings` 为 true 时按 git 默认函数名规则重算拆出来的 hunk 标题。
    public static func ignoringWhitespace(
        _ diff: GitFileDiff,
        context: GitDiffContext,
        recomputesSectionHeadings: Bool = false
    ) -> GitFileDiff {
        GitDiffReshaper.reshape(
            diff,
            context: context,
            mergesWhitespace: true,
            renumbersLines: false,
            recomputesSectionHeadings: recomputesSectionHeadings
        )
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

/// 两个公共入口共用的流程：分组 →（可选）合并只差空白的行 → 按上下文行数重切 → 生成 hunk。
private enum GitDiffReshaper {
    /// 中段删除数×新增数超过这个值就不做 LCS，整段按改动保留，避免大块改写退化成平方级。
    private static let maximumAlignedCells = 1_000_000
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
               mergeWhitespaceOnlyChanges(in: &entries, keys: &keys, nextLineID: &nextMergedLineID) {
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

    // MARK: - 块内对齐

    /// 逐个改动块合并只差空白的行；返回是否有行被并成上下文。
    private static func mergeWhitespaceOnlyChanges(
        in entries: inout [Entry],
        keys: inout WhitespaceInsensitiveKeys,
        nextLineID: inout Int
    ) -> Bool {
        var result: [Entry] = []
        var merged = false
        var index = 0
        while index < entries.count {
            guard entries[index].isChange else {
                if merged { result.append(entries[index]) }
                index += 1
                continue
            }
            let start = index
            while index < entries.count, entries[index].isChange {
                index += 1
            }
            let block = entries[start..<index]
            if let realigned = realign(block, keys: &keys, nextLineID: &nextLineID) {
                if !merged {
                    result.reserveCapacity(entries.count)
                    result.append(contentsOf: entries[0..<start])
                    merged = true
                }
                result.append(contentsOf: realigned)
            } else if merged {
                result.append(contentsOf: block)
            }
        }
        if merged {
            entries = result
        }
        return merged
    }

    /// 块内删除、新增各自按原顺序对齐；没有可合并的行时返回 nil，调用方原样保留整块。
    private static func realign(
        _ block: ArraySlice<Entry>,
        keys: inout WhitespaceInsensitiveKeys,
        nextLineID: inout Int
    ) -> [Entry]? {
        var deletions: [Entry] = []
        var additions: [Entry] = []
        for entry in block {
            switch entry.line.kind {
            case .deletion: deletions.append(entry)
            case .addition: additions.append(entry)
            case .context, .metadata: return nil
            }
        }
        guard !deletions.isEmpty, !additions.isEmpty else {
            return nil
        }

        // 带 metadata 后缀的行（文件末尾无换行）不参与合并，键为 -1 表示永不相等。
        let deletionKeys = deletions.map { $0.trailing.isEmpty ? keys.key(for: $0.line.content) : -1 }
        let additionKeys = additions.map { $0.trailing.isEmpty ? keys.key(for: $0.line.content) : -1 }
        let pairs = matchedPairs(deletionKeys, additionKeys)
        guard !pairs.isEmpty else {
            return nil
        }

        var result: [Entry] = []
        result.reserveCapacity(block.count)
        var deletionCursor = 0
        var additionCursor = 0
        for (deletionIndex, additionIndex) in pairs {
            result.append(contentsOf: deletions[deletionCursor..<deletionIndex])
            result.append(contentsOf: additions[additionCursor..<additionIndex])
            let deletion = deletions[deletionIndex].line
            let addition = additions[additionIndex].line
            // git -w 的上下文行取新侧内容；id 另起，避免和原 diff 里的改动行撞号。
            result.append(
                Entry(
                    line: GitDiffLine(
                        id: nextLineID,
                        kind: .context,
                        oldLineNumber: deletion.oldLineNumber,
                        newLineNumber: addition.newLineNumber,
                        content: addition.content
                    ),
                    oldContent: deletion.content
                )
            )
            nextLineID += 1
            deletionCursor = deletionIndex + 1
            additionCursor = additionIndex + 1
        }
        result.append(contentsOf: deletions[deletionCursor...])
        result.append(contentsOf: additions[additionCursor...])
        return result
    }

    /// 先剥公共前缀、后缀，中段规模可控时做 LCS。结果按两侧下标递增。
    private static func matchedPairs(_ old: [Int], _ new: [Int]) -> [(Int, Int)] {
        func same(_ lhs: Int, _ rhs: Int) -> Bool {
            lhs >= 0 && lhs == rhs
        }

        var pairs: [(Int, Int)] = []
        var prefix = 0
        while prefix < old.count, prefix < new.count, same(old[prefix], new[prefix]) {
            pairs.append((prefix, prefix))
            prefix += 1
        }
        var suffix = 0
        while suffix < old.count - prefix,
              suffix < new.count - prefix,
              same(old[old.count - 1 - suffix], new[new.count - 1 - suffix]) {
            suffix += 1
        }

        let rows = old.count - prefix - suffix
        let columns = new.count - prefix - suffix
        if rows > 0, columns > 0, rows * columns <= maximumAlignedCells {
            let middle = longestCommonSubsequence(
                old[prefix..<(prefix + rows)],
                new[prefix..<(prefix + columns)]
            )
            for (row, column) in middle {
                pairs.append((prefix + row, prefix + column))
            }
        }

        for offset in 0..<suffix {
            pairs.append((old.count - suffix + offset, new.count - suffix + offset))
        }
        return pairs
    }

    /// 返回的下标相对切片起点。能匹配就尽早匹配，相当于把剩下的改动往后推，与 git 滑动改动组的方向一致。
    private static func longestCommonSubsequence(
        _ old: ArraySlice<Int>,
        _ new: ArraySlice<Int>
    ) -> [(Int, Int)] {
        let oldKeys = Array(old)
        let newKeys = Array(new)
        let newKeySet = Set(newKeys.lazy.filter { $0 >= 0 })
        guard oldKeys.contains(where: { $0 >= 0 && newKeySet.contains($0) }) else {
            return []
        }

        let rows = oldKeys.count
        let columns = newKeys.count
        let width = columns + 1
        var lengths = [Int32](repeating: 0, count: (rows + 1) * width)
        lengths.withUnsafeMutableBufferPointer { table in
            for row in stride(from: rows - 1, through: 0, by: -1) {
                let key = oldKeys[row]
                let current = row * width
                let below = current + width
                for column in stride(from: columns - 1, through: 0, by: -1) {
                    if key >= 0, key == newKeys[column] {
                        table[current + column] = table[below + column + 1] + 1
                    } else {
                        table[current + column] = max(table[below + column], table[current + column + 1])
                    }
                }
            }
        }

        var pairs: [(Int, Int)] = []
        var row = 0
        var column = 0
        while row < rows, column < columns {
            let key = oldKeys[row]
            if key >= 0, key == newKeys[column] {
                pairs.append((row, column))
                row += 1
                column += 1
            } else if lengths[(row + 1) * width + column] >= lengths[row * width + column + 1] {
                row += 1
            } else {
                column += 1
            }
        }
        return pairs
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
        let text = String(decoding: bytes, as: UTF8.self)
        let parsed = text.trimmingCharacters(in: .whitespaces)
        return SectionHeading(text: text, parsed: parsed.isEmpty ? nil : parsed)
    }
}

/// git 的 `isspace` 只认空格、`\t`、`\n`、`\r`（`\v`、`\f` 不算）。
private func isGitSpace(_ byte: UInt8) -> Bool {
    byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
}

/// 去掉空白后的行内容映射成整数，块内 LCS 只比整数。
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
