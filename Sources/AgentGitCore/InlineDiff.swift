import Foundation

/// 行内高亮区间。偏移用 UTF-16，渲染层可以直接拿去做 NSRange，不再逐行换算。
public struct GitDiffInlineRange: Hashable, Codable, Sendable {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

/// 配对的删除行与新增行之间求字符级差异。
public enum InlineDiffCalculator {
    /// 中段超过这个 token 数就不再做 LCS，只保留粗粒度区间；避免长行退化成 O(n²)。
    private static let maximumRefinedTokens = 200
    private static let maximumComparedScalars = 65_536
    /// 整个 hunk 共用预算，避免每对行的上限随着行数累加。
    private static let maximumComparedBytes = 1_048_576
    private static let maximumComparedPairs = 1_024
    private static let maximumRefinementCells = 200_000

    /// 统一 diff 里删除行成组、新增行成组，按下标一一配对是各家 diff 视图的通行做法。
    public static func annotate(_ lines: [GitDiffLine]) -> [GitDiffLine] {
        var result = lines
        var index = 0
        var budget = WorkBudget()

        while index < result.count {
            guard !Task.isCancelled else {
                return result
            }
            guard result[index].kind == .deletion else {
                index += 1
                continue
            }

            let deletionStart = index
            while index < result.count, result[index].kind == .deletion {
                index += 1
            }
            let additionStart = index
            while index < result.count, result[index].kind == .addition {
                index += 1
            }

            let deletionCount = additionStart - deletionStart
            let additionCount = index - additionStart
            for offset in 0..<min(deletionCount, additionCount) {
                guard !Task.isCancelled, budget.canCompare else {
                    return result
                }
                let oldIndex = deletionStart + offset
                let newIndex = additionStart + offset
                let (oldRanges, newRanges) = ranges(
                    old: result[oldIndex].content,
                    new: result[newIndex].content,
                    budget: &budget
                )
                result[oldIndex] = result[oldIndex].withInlineRanges(oldRanges)
                result[newIndex] = result[newIndex].withInlineRanges(newRanges)
            }
        }

        return result
    }

    public static func ranges(
        old: String,
        new: String
    ) -> (old: [GitDiffInlineRange], new: [GitDiffInlineRange]) {
        var budget = WorkBudget()
        return ranges(old: old, new: new, budget: &budget)
    }

    private struct WorkBudget {
        var remainingBytes = InlineDiffCalculator.maximumComparedBytes
        var remainingPairs = InlineDiffCalculator.maximumComparedPairs
        var remainingRefinementCells = InlineDiffCalculator.maximumRefinementCells

        var canCompare: Bool {
            remainingBytes > 0 && remainingPairs > 0
        }
    }

    private static func ranges(
        old: String,
        new: String,
        budget: inout WorkBudget
    ) -> (old: [GitDiffInlineRange], new: [GitDiffInlineRange]) {
        guard !Task.isCancelled, budget.canCompare else {
            return ([], [])
        }
        budget.remainingPairs -= 1
        guard !old.isEmpty, !new.isEmpty,
              let oldBytes = comparedBytes(old, budget: &budget),
              let newBytes = comparedBytes(new, budget: &budget),
              oldBytes != newBytes else {
            return ([], [])
        }

        // CRLF 在 Character 中算一个字符，含 CR 的行继续走字符路径。
        if oldBytes.allSatisfy({ $0 < 128 && $0 != 13 }),
           newBytes.allSatisfy({ $0 < 128 && $0 != 13 }) {
            guard oldBytes.count <= maximumComparedScalars,
                  newBytes.count <= maximumComparedScalars else {
                return ([], [])
            }
            let (oldSpans, newSpans) = changedSpans(
                oldBytes, newBytes, isWord: isWordByte, budget: &budget
            )
            return (
                oldSpans.map { GitDiffInlineRange(location: $0.start, length: $0.count) },
                newSpans.map { GitDiffInlineRange(location: $0.start, length: $0.count) }
            )
        }

        guard old.unicodeScalars.prefix(maximumComparedScalars + 1).count <= maximumComparedScalars,
              new.unicodeScalars.prefix(maximumComparedScalars + 1).count <= maximumComparedScalars else {
            return ([], [])
        }
        let oldCharacters = Array(old)
        let newCharacters = Array(new)
        let (oldSpans, newSpans) = changedSpans(
            oldCharacters, newCharacters, isWord: isWordCharacter, budget: &budget
        )
        return (
            inlineRanges(oldSpans, characters: oldCharacters),
            inlineRanges(newSpans, characters: newCharacters)
        )
    }

    /// UTF-8 每个 scalar 最多四个字节，读取到上限就停止，不先扫描完整长行。
    private static func comparedBytes(_ text: String, budget: inout WorkBudget) -> [UInt8]? {
        let limit = min(maximumComparedScalars * 4, budget.remainingBytes)
        let bytes = Array(text.utf8.prefix(limit + 1))
        budget.remainingBytes -= min(bytes.count, budget.remainingBytes)
        guard bytes.count <= limit else {
            return nil
        }
        return bytes
    }

    private static func changedSpans<Element: Hashable>(
        _ oldElements: [Element],
        _ newElements: [Element],
        isWord: (Element) -> Bool,
        budget: inout WorkBudget
    ) -> (old: [Span], new: [Span]) {
        var prefix = 0
        while prefix < oldElements.count,
              prefix < newElements.count,
              oldElements[prefix] == newElements[prefix] {
            prefix += 1
        }

        var suffix = 0
        while suffix < oldElements.count - prefix,
              suffix < newElements.count - prefix,
              oldElements[oldElements.count - 1 - suffix]
                == newElements[newElements.count - 1 - suffix] {
            suffix += 1
        }

        // 裁剪不能停在单词中间，避免只高亮标识符的一部分。
        while prefix > 0,
              isWord(oldElements[prefix - 1]),
              isWordElement(oldElements, at: prefix, matching: isWord)
                || isWordElement(newElements, at: prefix, matching: isWord) {
            prefix -= 1
        }
        while suffix > 0,
              isWordElement(oldElements, at: oldElements.count - suffix, matching: isWord),
              isWordElement(oldElements, at: oldElements.count - suffix - 1, matching: isWord)
                || isWordElement(newElements, at: newElements.count - suffix - 1, matching: isWord) {
            suffix -= 1
        }

        // 整行都不同就没有“行内”可言，交给整行底色表达即可。
        guard prefix > 0 || suffix > 0 else {
            return ([], [])
        }

        let oldEnd = oldElements.count - suffix
        let newEnd = newElements.count - suffix
        guard prefix < oldEnd || prefix < newEnd else {
            return ([], [])
        }

        let coarseSpans = (
            old: prefix < oldEnd ? [Span(start: prefix, count: oldEnd - prefix)] : [],
            new: prefix < newEnd ? [Span(start: prefix, count: newEnd - prefix)] : []
        )
        guard budget.remainingRefinementCells > 0,
              let oldTokens = tokenize(oldElements, in: prefix..<oldEnd, isWord: isWord),
              let newTokens = tokenize(newElements, in: prefix..<newEnd, isWord: isWord) else {
            return coarseSpans
        }

        // 绝大多数改动就是一个 token 变了，没必要为此建 DP 表。
        if oldTokens.isEmpty || newTokens.isEmpty
            || (oldTokens.count <= 1 && newTokens.count <= 1) {
            return coarseSpans
        }

        let cells = (oldTokens.count + 1) * (newTokens.count + 1)
        guard cells <= budget.remainingRefinementCells, !Task.isCancelled else {
            return coarseSpans
        }
        budget.remainingRefinementCells -= cells
        return differingSpans(oldTokens, newTokens, oldElements: oldElements, newElements: newElements)
    }

    private struct Span {
        let start: Int
        let count: Int
    }

    private struct Token {
        let start: Int
        let count: Int
    }

    /// 按标识符切分：连续的字母数字下划线算一个 token，其余字符各自成一个。
    private static func tokenize<Element>(
        _ elements: [Element],
        in bounds: Range<Int>,
        isWord: (Element) -> Bool
    ) -> [Token]? {
        var tokens: [Token] = []
        var index = bounds.lowerBound
        while index < bounds.upperBound {
            let start = index
            if isWord(elements[index]) {
                while index < bounds.upperBound, isWord(elements[index]) {
                    index += 1
                }
            } else {
                index += 1
            }
            tokens.append(
                Token(start: start, count: index - start)
            )
            guard tokens.count <= maximumRefinedTokens else {
                return nil
            }
        }
        return tokens
    }

    private static func isWordByte(_ byte: UInt8) -> Bool {
        (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
            || (byte >= 48 && byte <= 57) || byte == 95
    }

    /// 只把 ASCII 标识符当“词”。CJK 没有词边界，整段连起来会让高亮退化成整句。
    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "_")
    }

    private static func isWordElement<Element>(
        _ elements: [Element],
        at index: Int,
        matching isWord: (Element) -> Bool
    ) -> Bool {
        guard elements.indices.contains(index) else {
            return false
        }
        return isWord(elements[index])
    }

    /// token 级 LCS，未匹配上的连续 token 合并成一个高亮区间。
    private static func differingSpans<Element: Hashable>(
        _ oldTokens: [Token],
        _ newTokens: [Token],
        oldElements: [Element],
        newElements: [Element]
    ) -> (old: [Span], new: [Span]) {
        // 先为 token 分配整数 ID，长标识符不会在每个 DP cell 重复扫描。
        var tokenIDs: [[Element]: Int] = [:]
        func identifiers(_ tokens: [Token], in elements: [Element]) -> [Int] {
            tokens.map { token in
                let text = Array(elements[token.start..<(token.start + token.count)])
                if let identifier = tokenIDs[text] {
                    return identifier
                }
                let identifier = tokenIDs.count
                tokenIDs[text] = identifier
                return identifier
            }
        }
        let oldIDs = identifiers(oldTokens, in: oldElements)
        let newIDs = identifiers(newTokens, in: newElements)
        let rows = oldTokens.count
        let columns = newTokens.count
        let width = columns + 1
        var lengths = Array(repeating: 0, count: (rows + 1) * width)
        for row in stride(from: rows - 1, through: 0, by: -1) {
            let rowStart = row * width
            let nextRowStart = rowStart + width
            for column in stride(from: columns - 1, through: 0, by: -1) {
                if oldIDs[row] == newIDs[column] {
                    lengths[rowStart + column] = lengths[nextRowStart + column + 1] + 1
                } else {
                    lengths[rowStart + column] = max(
                        lengths[nextRowStart + column], lengths[rowStart + column + 1]
                    )
                }
            }
        }

        var oldChanged = Array(repeating: true, count: rows)
        var newChanged = Array(repeating: true, count: columns)
        var row = 0
        var column = 0
        while row < rows, column < columns {
            if oldIDs[row] == newIDs[column] {
                oldChanged[row] = false
                newChanged[column] = false
                row += 1
                column += 1
            } else if lengths[(row + 1) * width + column] >= lengths[row * width + column + 1] {
                row += 1
            } else {
                column += 1
            }
        }

        return (spans(oldTokens, oldChanged), spans(newTokens, newChanged))
    }

    private static func spans(_ tokens: [Token], _ changed: [Bool]) -> [Span] {
        var spans: [Span] = []
        var index = 0
        while index < tokens.count {
            guard changed[index] else {
                index += 1
                continue
            }
            let start = tokens[index].start
            var end = tokens[index].start + tokens[index].count
            while index + 1 < tokens.count, changed[index + 1] {
                index += 1
                end = tokens[index].start + tokens[index].count
            }
            spans.append(Span(start: start, count: end - start))
            index += 1
        }
        return spans
    }

    /// 一次建立字符到 UTF-16 的偏移表，多个区间共用，保持完整字符的边界。
    private static func inlineRanges(_ spans: [Span], characters: [Character]) -> [GitDiffInlineRange] {
        guard !spans.isEmpty else {
            return []
        }
        var offsets = [0]
        offsets.reserveCapacity(characters.count + 1)
        for character in characters {
            offsets.append(offsets[offsets.count - 1] + character.utf16.count)
        }
        return spans.map { span in
            GitDiffInlineRange(
                location: offsets[span.start],
                length: offsets[span.start + span.count] - offsets[span.start]
            )
        }
    }
}
