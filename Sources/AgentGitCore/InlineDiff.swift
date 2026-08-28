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

    /// 统一 diff 里删除行成组、新增行成组，按下标一一配对是各家 diff 视图的通行做法。
    public static func annotate(_ lines: [GitDiffLine]) -> [GitDiffLine] {
        var result = lines
        var index = 0

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
                guard !Task.isCancelled else {
                    return result
                }
                let oldIndex = deletionStart + offset
                let newIndex = additionStart + offset
                let (oldRanges, newRanges) = ranges(
                    old: result[oldIndex].content,
                    new: result[newIndex].content
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
        let oldCharacters = Array(old)
        let newCharacters = Array(new)
        guard !oldCharacters.isEmpty, !newCharacters.isEmpty else {
            return ([], [])
        }

        var prefix = 0
        while prefix < oldCharacters.count,
              prefix < newCharacters.count,
              oldCharacters[prefix] == newCharacters[prefix] {
            prefix += 1
        }

        var suffix = 0
        while suffix < oldCharacters.count - prefix,
              suffix < newCharacters.count - prefix,
              oldCharacters[oldCharacters.count - 1 - suffix]
                == newCharacters[newCharacters.count - 1 - suffix] {
            suffix += 1
        }

        // 裁剪不能停在单词中间，否则会highlight出 "be|ta" 这种半截 token。
        while prefix > 0,
              isWordCharacter(oldCharacters[prefix - 1]),
              isWordCharacter(oldCharacters, at: prefix)
                || isWordCharacter(newCharacters, at: prefix) {
            prefix -= 1
        }
        while suffix > 0,
              isWordCharacter(oldCharacters, at: oldCharacters.count - suffix),
              isWordCharacter(oldCharacters, at: oldCharacters.count - suffix - 1)
                || isWordCharacter(newCharacters, at: newCharacters.count - suffix - 1) {
            suffix -= 1
        }

        // 整行都不同就没有“行内”可言，交给整行底色表达即可。
        guard prefix > 0 || suffix > 0 else {
            return ([], [])
        }

        let oldMiddle = Array(oldCharacters[prefix..<(oldCharacters.count - suffix)])
        let newMiddle = Array(newCharacters[prefix..<(newCharacters.count - suffix)])
        guard !oldMiddle.isEmpty || !newMiddle.isEmpty else {
            return ([], [])
        }

        let oldTokens = tokenize(oldMiddle)
        let newTokens = tokenize(newMiddle)
        guard oldTokens.count <= maximumRefinedTokens,
              newTokens.count <= maximumRefinedTokens else {
            return (
                [inlineRange(oldCharacters, from: prefix, count: oldMiddle.count)],
                [inlineRange(newCharacters, from: prefix, count: newMiddle.count)]
            )
        }

        // 绝大多数改动就是一个 token 变了，没必要为此建 DP 表。
        if oldTokens.count <= 1, newTokens.count <= 1 {
            return (
                oldMiddle.isEmpty
                    ? []
                    : [inlineRange(oldCharacters, from: prefix, count: oldMiddle.count)],
                newMiddle.isEmpty
                    ? []
                    : [inlineRange(newCharacters, from: prefix, count: newMiddle.count)]
            )
        }

        let (oldSpans, newSpans) = differingSpans(oldTokens, newTokens)
        return (
            oldSpans.map { inlineRange(oldCharacters, from: prefix + $0.start, count: $0.count) },
            newSpans.map { inlineRange(newCharacters, from: prefix + $0.start, count: $0.count) }
        )
    }

    private struct Span {
        let start: Int
        let count: Int
    }

    private struct Token {
        let start: Int
        let count: Int
        let text: ArraySlice<Character>
    }

    /// 按标识符切分：连续的字母数字下划线算一个 token，其余字符各自成一个。
    private static func tokenize(_ characters: [Character]) -> [Token] {
        var tokens: [Token] = []
        var index = 0
        while index < characters.count {
            let start = index
            if isWordCharacter(characters[index]) {
                while index < characters.count, isWordCharacter(characters[index]) {
                    index += 1
                }
            } else {
                index += 1
            }
            tokens.append(
                Token(start: start, count: index - start, text: characters[start..<index])
            )
        }
        return tokens
    }

    /// 只把 ASCII 标识符当“词”。CJK 没有词边界，整段连起来会让高亮退化成整句。
    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "_")
    }

    private static func isWordCharacter(_ characters: [Character], at index: Int) -> Bool {
        guard characters.indices.contains(index) else {
            return false
        }
        return isWordCharacter(characters[index])
    }

    /// token 级 LCS，未匹配上的连续 token 合并成一个高亮区间。
    private static func differingSpans(
        _ oldTokens: [Token],
        _ newTokens: [Token]
    ) -> (old: [Span], new: [Span]) {
        let rows = oldTokens.count
        let columns = newTokens.count
        var lengths = Array(
            repeating: Array(repeating: 0, count: columns + 1),
            count: rows + 1
        )
        for row in stride(from: rows - 1, through: 0, by: -1) {
            for column in stride(from: columns - 1, through: 0, by: -1) {
                if oldTokens[row].text.elementsEqual(newTokens[column].text) {
                    lengths[row][column] = lengths[row + 1][column + 1] + 1
                } else {
                    lengths[row][column] = max(lengths[row + 1][column], lengths[row][column + 1])
                }
            }
        }

        var oldChanged = Array(repeating: true, count: rows)
        var newChanged = Array(repeating: true, count: columns)
        var row = 0
        var column = 0
        while row < rows, column < columns {
            if oldTokens[row].text.elementsEqual(newTokens[column].text) {
                oldChanged[row] = false
                newChanged[column] = false
                row += 1
                column += 1
            } else if lengths[row + 1][column] >= lengths[row][column + 1] {
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

    /// 字符下标换算成 UTF-16 偏移，渲染层可以直接当 NSRange 用。
    private static func inlineRange(
        _ characters: [Character],
        from start: Int,
        count: Int
    ) -> GitDiffInlineRange {
        let location = characters[0..<start].reduce(0) { $0 + $1.utf16.count }
        let length = characters[start..<(start + count)].reduce(0) { $0 + $1.utf16.count }
        return GitDiffInlineRange(location: location, length: length)
    }
}
