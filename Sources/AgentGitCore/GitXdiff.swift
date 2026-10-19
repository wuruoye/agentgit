import Foundation

/// 按 git xdiff 默认流程（Myers + 缩进启发）求两组行之间的改动，行是否相同只看调用方给的键。
/// 忽略空白时传去空白后的键，在同一段内容上与 `git diff --ignore-all-space` 选出同样的改动行。
/// 依次对应 xdiff 的 `xdl_trim_ends`、`xdl_cleanup_records`、`xdl_recs_cmp`/`xdl_split`、`xdl_change_compact`，
/// 常量与分支保持原样，改了任何一处都可能和 git 选出不同的对齐。
enum GitXdiff {
    struct Line {
        let key: Int
        /// git `get_indent` 的结果，见 `indent(of:)`。
        let indent: Int
    }

    /// 返回两侧每一行是否属于改动；改动组在两侧对不上时返回 nil，调用方保留原结果。
    static func changedLines(old: [Line], new: [Line]) -> (old: [Bool], new: [Bool])? {
        var oldSide = Side(lines: old)
        var newSide = Side(lines: new)
        markChanges(&oldSide, &newSide)
        guard compact(&oldSide, other: &newSide), compact(&newSide, other: &oldSide) else {
            return nil
        }
        return (oldSide.changedLines, newSide.changedLines)
    }

    /// git `get_indent`：行首空格计 1、制表符补到下一个 8 的倍数，最多 200；整行都是空白返回 -1。
    static func indent(of content: String) -> Int {
        var indent = 0
        for byte in content.utf8 {
            switch byte {
            case 0x20: indent += 1
            case 0x09: indent += 8 - indent % 8
            // git 的 isspace 只认空格、`\t`、`\n`、`\r`，其余空白字符不算缩进也不结束扫描。
            case 0x0A, 0x0D: break
            default: return indent
            }
            if indent >= maximumIndent {
                return maximumIndent
            }
        }
        return -1
    }

    private static let maximumIndent = 200
    private static let maximumEqualLimit = 1_024
    private static let similarScanWindow = 100
    private static let multimatchRunFactor = 4
    private static let minimumMaximumCost = 256
    private static let heuristicMinimumCost = 256
    private static let snakeCount = 20
    private static let heuristicFactor = 4

    // MARK: - 行标记

    /// 前后各留一个恒为 false 的哨兵，读 -1 和 count 位置不用另判边界，与 xdiff 的 `rchg` 一致。
    private struct Side {
        let keys: [Int]
        let indents: [Int]
        private var flags: [Bool]

        init(lines: [Line]) {
            keys = lines.map(\.key)
            indents = lines.map(\.indent)
            flags = [Bool](repeating: false, count: lines.count + 2)
        }

        var count: Int {
            keys.count
        }

        var changedLines: [Bool] {
            Array(flags[1...count])
        }

        func isChanged(_ line: Int) -> Bool {
            flags[line + 1]
        }

        mutating func setChanged(_ line: Int, _ changed: Bool) {
            flags[line + 1] = changed
        }
    }

    /// `xdl_prepare_env` + `xdl_do_diff`：键先压成连续编号并统计两侧出现次数，再裁掉首尾相同的行。
    private static func markChanges(_ old: inout Side, _ new: inout Side) {
        var classes: [Int: Int] = [:]
        var oldCounts: [Int] = []
        var newCounts: [Int] = []
        func classify(_ key: Int) -> Int {
            if let index = classes[key] {
                return index
            }
            let index = classes.count
            classes[key] = index
            oldCounts.append(0)
            newCounts.append(0)
            return index
        }
        let oldClasses = old.keys.map(classify)
        let newClasses = new.keys.map(classify)
        for index in oldClasses { oldCounts[index] += 1 }
        for index in newClasses { newCounts[index] += 1 }

        let limit = min(old.count, new.count)
        var start = 0
        while start < limit, oldClasses[start] == newClasses[start] {
            start += 1
        }
        var tail = 0
        while tail < limit - start,
              oldClasses[old.count - 1 - tail] == newClasses[new.count - 1 - tail] {
            tail += 1
        }

        let oldRecords = candidateRecords(
            oldClasses, otherCounts: newCounts, start: start, end: old.count - tail - 1, side: &old
        )
        let newRecords = candidateRecords(
            newClasses, otherCounts: oldCounts, start: start, end: new.count - tail - 1, side: &new
        )
        compareRecords(oldRecords, newRecords, old: &old, new: &new)
    }

    /// `xdl_cleanup_records`：对面没有的行直接算改动；对面出现太多次、又夹在这类行中间的行也算改动。
    private static func candidateRecords(
        _ classes: [Int], otherCounts: [Int], start: Int, end: Int, side: inout Side
    ) -> (hashes: [Int], lines: [Int]) {
        guard start <= end else {
            return ([], [])
        }
        let limit = min(bogoSquareRoot(classes.count), maximumEqualLimit)
        var discard = [UInt8](repeating: 0, count: classes.count + 1)
        for line in start...end {
            let matches = otherCounts[classes[line]]
            discard[line] = matches == 0 ? 0 : matches >= limit ? 2 : 1
        }
        var hashes: [Int] = []
        var lines: [Int] = []
        for line in start...end {
            if discard[line] == 1
                || (discard[line] == 2 && !isIsolatedMultimatch(discard, line, start: start, end: end)) {
                hashes.append(classes[line])
                lines.append(line)
            } else {
                side.setChanged(line, true)
            }
        }
        return (hashes, lines)
    }

    /// `xdl_clean_mmatch`：前后都挨着无匹配行，且多匹配行在这一串里占比不到四分之一时丢掉。
    private static func isIsolatedMultimatch(_ discard: [UInt8], _ line: Int, start: Int, end: Int) -> Bool {
        /// 从 `line` 往一个方向数，碰到普通匹配行停：返回无匹配行数和（含自身的）多匹配行数。
        func run(_ lines: StrideThrough<Int>) -> (unmatched: Int, multimatch: Int) {
            var unmatched = 0
            var multimatch = 1
            for index in lines {
                if discard[index] == 0 {
                    unmatched += 1
                } else if discard[index] == 2 {
                    multimatch += 1
                } else {
                    break
                }
            }
            return (unmatched, multimatch)
        }

        let before = run(stride(from: line - 1, through: max(start, line - similarScanWindow), by: -1))
        guard before.unmatched > 0 else {
            return false
        }
        let after = run(stride(from: line + 1, through: min(end, line + similarScanWindow), by: 1))
        guard after.unmatched > 0 else {
            return false
        }
        let unmatched = before.unmatched + after.unmatched
        let multimatch = before.multimatch + after.multimatch
        return multimatch * multimatchRunFactor < multimatch + unmatched
    }

    /// `xdl_bogosqrt`。
    private static func bogoSquareRoot(_ value: Int) -> Int {
        var value = value
        var root = 1
        while value > 0 {
            root <<= 1
            value >>= 2
        }
        return root
    }

    // MARK: - Myers

    private struct Split {
        let oldIndex: Int
        let newIndex: Int
        let minimalLow: Bool
        let minimalHigh: Bool
    }

    private struct Box {
        var oldStart: Int
        var oldEnd: Int
        var newStart: Int
        var newEnd: Int
        let needsMinimal: Bool
    }

    /// `xdl_recs_cmp`：用显式栈代替递归，先处理低半边，处理顺序与 git 相同，复用的对角线数组状态也相同。
    private static func compareRecords(
        _ oldRecords: (hashes: [Int], lines: [Int]),
        _ newRecords: (hashes: [Int], lines: [Int]),
        old: inout Side,
        new: inout Side
    ) {
        let oldHashes = oldRecords.hashes
        let newHashes = newRecords.hashes
        let diagonalCount = oldHashes.count + newHashes.count + 3
        let maximumCost = max(bogoSquareRoot(diagonalCount), minimumMaximumCost)
        var forward = [Int](repeating: 0, count: diagonalCount)
        var backward = [Int](repeating: 0, count: diagonalCount)
        var boxes = [Box(
            oldStart: 0, oldEnd: oldHashes.count, newStart: 0, newEnd: newHashes.count, needsMinimal: false
        )]

        oldHashes.withUnsafeBufferPointer { oldHashes in
            newHashes.withUnsafeBufferPointer { newHashes in
                forward.withUnsafeMutableBufferPointer { forward in
                    backward.withUnsafeMutableBufferPointer { backward in
                        // 对角线 d 的取值范围是 -(新侧数量 + 1) ... 旧侧数量 + 1，平移后从 0 开始。
                        let origin = newHashes.count + 1
                        let forwardDiagonals = forward.baseAddress! + origin
                        let backwardDiagonals = backward.baseAddress! + origin
                        while var box = boxes.popLast() {
                            while box.oldStart < box.oldEnd, box.newStart < box.newEnd,
                                  oldHashes[box.oldStart] == newHashes[box.newStart] {
                                box.oldStart += 1
                                box.newStart += 1
                            }
                            while box.oldStart < box.oldEnd, box.newStart < box.newEnd,
                                  oldHashes[box.oldEnd - 1] == newHashes[box.newEnd - 1] {
                                box.oldEnd -= 1
                                box.newEnd -= 1
                            }
                            if box.oldStart == box.oldEnd {
                                for index in box.newStart..<box.newEnd {
                                    new.setChanged(newRecords.lines[index], true)
                                }
                            } else if box.newStart == box.newEnd {
                                for index in box.oldStart..<box.oldEnd {
                                    old.setChanged(oldRecords.lines[index], true)
                                }
                            } else {
                                let split = split(
                                    box, oldHashes: oldHashes, newHashes: newHashes,
                                    forward: forwardDiagonals, backward: backwardDiagonals,
                                    maximumCost: maximumCost
                                )
                                boxes.append(Box(
                                    oldStart: split.oldIndex, oldEnd: box.oldEnd,
                                    newStart: split.newIndex, newEnd: box.newEnd,
                                    needsMinimal: split.minimalHigh
                                ))
                                boxes.append(Box(
                                    oldStart: box.oldStart, oldEnd: split.oldIndex,
                                    newStart: box.newStart, newEnd: split.newIndex,
                                    needsMinimal: split.minimalLow
                                ))
                            }
                        }
                    }
                }
            }
        }
    }

    /// `xdl_split`：前后两端同时推进找中间蛇；代价超过阈值后按 git 的启发提前取分割点。
    private static func split(
        _ box: Box,
        oldHashes: UnsafeBufferPointer<Int>,
        newHashes: UnsafeBufferPointer<Int>,
        forward: UnsafeMutablePointer<Int>,
        backward: UnsafeMutablePointer<Int>,
        maximumCost: Int
    ) -> Split {
        let off1 = box.oldStart, lim1 = box.oldEnd
        let off2 = box.newStart, lim2 = box.newEnd
        let dmin = off1 - lim2, dmax = lim1 - off2
        let fmid = off1 - off2, bmid = lim1 - lim2
        let odd = (fmid - bmid) & 1 != 0
        var fmin = fmid, fmax = fmid
        var bmin = bmid, bmax = bmid

        forward[fmid] = off1
        backward[bmid] = lim1

        var cost = 1
        while true {
            var gotSnake = false

            if fmin > dmin {
                fmin -= 1
                forward[fmin - 1] = -1
            } else {
                fmin += 1
            }
            if fmax < dmax {
                fmax += 1
                forward[fmax + 1] = -1
            } else {
                fmax -= 1
            }

            var d = fmax
            while d >= fmin {
                var i1 = forward[d - 1] >= forward[d + 1] ? forward[d - 1] + 1 : forward[d + 1]
                let previous = i1
                var i2 = i1 - d
                while i1 < lim1, i2 < lim2, oldHashes[i1] == newHashes[i2] {
                    i1 += 1
                    i2 += 1
                }
                if i1 - previous > snakeCount {
                    gotSnake = true
                }
                forward[d] = i1
                if odd, bmin <= d, d <= bmax, backward[d] <= i1 {
                    return Split(oldIndex: i1, newIndex: i2, minimalLow: true, minimalHigh: true)
                }
                d -= 2
            }

            if bmin > dmin {
                bmin -= 1
                backward[bmin - 1] = .max
            } else {
                bmin += 1
            }
            if bmax < dmax {
                bmax += 1
                backward[bmax + 1] = .max
            } else {
                bmax -= 1
            }

            d = bmax
            while d >= bmin {
                var i1 = backward[d - 1] < backward[d + 1] ? backward[d - 1] : backward[d + 1] - 1
                let previous = i1
                var i2 = i1 - d
                while i1 > off1, i2 > off2, oldHashes[i1 - 1] == newHashes[i2 - 1] {
                    i1 -= 1
                    i2 -= 1
                }
                if previous - i1 > snakeCount {
                    gotSnake = true
                }
                backward[d] = i1
                if !odd, fmin <= d, d <= fmax, i1 <= forward[d] {
                    return Split(oldIndex: i1, newIndex: i2, minimalLow: true, minimalHigh: true)
                }
                d -= 2
            }

            if box.needsMinimal {
                cost += 1
                continue
            }

            // 代价已经很高且出现过长蛇：取离起点（或终点）足够远、末端带一段长匹配的对角线。
            if gotSnake, cost > heuristicMinimumCost {
                var best = 0
                var bestSplit: (Int, Int) = (0, 0)
                d = fmax
                while d >= fmin {
                    let distance = d > fmid ? d - fmid : fmid - d
                    let i1 = forward[d]
                    let i2 = i1 - d
                    let value = (i1 - off1) + (i2 - off2) - distance
                    if value > heuristicFactor * cost, value > best,
                       off1 + snakeCount <= i1, i1 < lim1,
                       off2 + snakeCount <= i2, i2 < lim2 {
                        var k = 1
                        while oldHashes[i1 - k] == newHashes[i2 - k] {
                            if k == snakeCount {
                                best = value
                                bestSplit = (i1, i2)
                                break
                            }
                            k += 1
                        }
                    }
                    d -= 2
                }
                if best > 0 {
                    return Split(
                        oldIndex: bestSplit.0, newIndex: bestSplit.1, minimalLow: true, minimalHigh: false
                    )
                }

                d = bmax
                while d >= bmin {
                    let distance = d > bmid ? d - bmid : bmid - d
                    let i1 = backward[d]
                    let i2 = i1 - d
                    let value = (lim1 - i1) + (lim2 - i2) - distance
                    if value > heuristicFactor * cost, value > best,
                       off1 < i1, i1 <= lim1 - snakeCount,
                       off2 < i2, i2 <= lim2 - snakeCount {
                        var k = 0
                        while oldHashes[i1 + k] == newHashes[i2 + k] {
                            if k == snakeCount - 1 {
                                best = value
                                bestSplit = (i1, i2)
                                break
                            }
                            k += 1
                        }
                    }
                    d -= 2
                }
                if best > 0 {
                    return Split(
                        oldIndex: bestSplit.0, newIndex: bestSplit.1, minimalLow: false, minimalHigh: true
                    )
                }
            }

            // 代价到上限：取两端各自走得最远的位置，哪边更远用哪边。
            if cost >= maximumCost {
                var forwardBest = -1
                var forwardBestOld = -1
                d = fmax
                while d >= fmin {
                    var i1 = min(forward[d], lim1)
                    var i2 = i1 - d
                    if lim2 < i2 {
                        i1 = lim2 + d
                        i2 = lim2
                    }
                    if forwardBest < i1 + i2 {
                        forwardBest = i1 + i2
                        forwardBestOld = i1
                    }
                    d -= 2
                }

                var backwardBest = Int.max
                var backwardBestOld = Int.max
                d = bmax
                while d >= bmin {
                    var i1 = max(off1, backward[d])
                    var i2 = i1 - d
                    if i2 < off2 {
                        i1 = off2 + d
                        i2 = off2
                    }
                    if i1 + i2 < backwardBest {
                        backwardBest = i1 + i2
                        backwardBestOld = i1
                    }
                    d -= 2
                }

                if (lim1 + lim2) - backwardBest < forwardBest - (off1 + off2) {
                    return Split(
                        oldIndex: forwardBestOld, newIndex: forwardBest - forwardBestOld,
                        minimalLow: true, minimalHigh: false
                    )
                }
                return Split(
                    oldIndex: backwardBestOld, newIndex: backwardBest - backwardBestOld,
                    minimalLow: false, minimalHigh: true
                )
            }

            cost += 1
        }
    }

    // MARK: - 改动组滑动

    /// 一组连续改动行 `start..<end`；两侧的组按相同的未改动行一一对应，可以为空。
    private struct Group {
        var start = 0
        var end = 0
    }

    /// `xdl_change_compact`：每组先上滑到顶、再下滑到底并吞并碰到的组；能和对面的组对齐就对齐，
    /// 否则按缩进启发选位置。两侧的组在任何一步失去对应都返回 false。
    private static func compact(_ side: inout Side, other: inout Side) -> Bool {
        var group = firstGroup(side)
        var otherGroup = firstGroup(other)

        while true {
            if group.end != group.start {
                var groupSize = 0
                var earliestEnd = 0
                var endMatchingOther = -1
                repeat {
                    groupSize = group.end - group.start
                    endMatchingOther = -1

                    while slideUp(&side, &group) {
                        guard previousGroup(other, &otherGroup) else { return false }
                    }
                    earliestEnd = group.end
                    if otherGroup.end > otherGroup.start {
                        endMatchingOther = group.end
                    }

                    while slideDown(&side, &group) {
                        guard nextGroup(other, &otherGroup) else { return false }
                        if otherGroup.end > otherGroup.start {
                            endMatchingOther = group.end
                        }
                    }
                } while groupSize != group.end - group.start

                if group.end == earliestEnd {
                    // 无处可滑。
                } else if endMatchingOther != -1 {
                    while otherGroup.end == otherGroup.start {
                        guard slideUp(&side, &group), previousGroup(other, &otherGroup) else { return false }
                    }
                } else {
                    let bestShift = bestIndentShift(
                        side, group: group, groupSize: groupSize, earliestEnd: earliestEnd
                    )
                    while group.end > bestShift {
                        guard slideUp(&side, &group), previousGroup(other, &otherGroup) else { return false }
                    }
                }
            }

            guard nextGroup(side, &group) else {
                break
            }
            guard nextGroup(other, &otherGroup) else {
                return false
            }
        }
        return !nextGroup(other, &otherGroup)
    }

    private static func firstGroup(_ side: Side) -> Group {
        var group = Group()
        while side.isChanged(group.end) {
            group.end += 1
        }
        return group
    }

    private static func nextGroup(_ side: Side, _ group: inout Group) -> Bool {
        guard group.end != side.count else {
            return false
        }
        group.start = group.end + 1
        group.end = group.start
        while side.isChanged(group.end) {
            group.end += 1
        }
        return true
    }

    private static func previousGroup(_ side: Side, _ group: inout Group) -> Bool {
        guard group.start != 0 else {
            return false
        }
        group.end = group.start - 1
        group.start = group.end
        while side.isChanged(group.start - 1) {
            group.start -= 1
        }
        return true
    }

    private static func slideDown(_ side: inout Side, _ group: inout Group) -> Bool {
        guard group.end < side.count, side.keys[group.start] == side.keys[group.end] else {
            return false
        }
        side.setChanged(group.start, false)
        group.start += 1
        side.setChanged(group.end, true)
        group.end += 1
        while side.isChanged(group.end) {
            group.end += 1
        }
        return true
    }

    private static func slideUp(_ side: inout Side, _ group: inout Group) -> Bool {
        guard group.start > 0, side.keys[group.start - 1] == side.keys[group.end - 1] else {
            return false
        }
        group.start -= 1
        side.setChanged(group.start, true)
        group.end -= 1
        side.setChanged(group.end, false)
        while side.isChanged(group.start - 1) {
            group.start -= 1
        }
        return true
    }

    // MARK: - 缩进启发

    private static let maximumBlankLines = 20
    private static let maximumSliding = 100
    private static let startOfFilePenalty = 1
    private static let endOfFilePenalty = 21
    private static let totalBlankWeight = -30
    private static let postBlankWeight = 6
    private static let relativeIndentPenalty = -4
    private static let relativeIndentWithBlankPenalty = 10
    private static let relativeOutdentPenalty = 24
    private static let relativeOutdentWithBlankPenalty = 17
    private static let relativeDedentPenalty = 23
    private static let relativeDedentWithBlankPenalty = 17
    private static let indentWeight = 60

    private struct SplitMeasurement {
        var endOfFile = false
        var indent = -1
        var preBlank = 0
        var preIndent = -1
        var postBlank = 0
        var postIndent = -1
    }

    private struct SplitScore {
        var effectiveIndent = 0
        var penalty = 0
    }

    /// 组当前在最下方；逐个评估上移后的位置，分数相同取更靠下的。
    private static func bestIndentShift(_ side: Side, group: Group, groupSize: Int, earliestEnd: Int) -> Int {
        var shift = max(earliestEnd, group.end - groupSize - 1, group.end - maximumSliding)
        var bestShift = -1
        var bestScore = SplitScore()
        while shift <= group.end {
            var score = SplitScore()
            addSplitScore(measureSplit(side, at: shift), to: &score)
            addSplitScore(measureSplit(side, at: shift - groupSize), to: &score)
            if bestShift == -1 || compareScores(score, bestScore) <= 0 {
                bestScore = score
                bestShift = shift
            }
            shift += 1
        }
        return bestShift
    }

    private static func measureSplit(_ side: Side, at split: Int) -> SplitMeasurement {
        var measurement = SplitMeasurement()
        if split >= side.count {
            measurement.endOfFile = true
            measurement.indent = -1
        } else {
            measurement.indent = side.indents[split]
        }

        var line = split - 1
        while line >= 0 {
            measurement.preIndent = side.indents[line]
            if measurement.preIndent != -1 {
                break
            }
            measurement.preBlank += 1
            if measurement.preBlank == maximumBlankLines {
                measurement.preIndent = 0
                break
            }
            line -= 1
        }

        line = split + 1
        while line < side.count {
            measurement.postIndent = side.indents[line]
            if measurement.postIndent != -1 {
                break
            }
            measurement.postBlank += 1
            if measurement.postBlank == maximumBlankLines {
                measurement.postIndent = 0
                break
            }
            line += 1
        }
        return measurement
    }

    private static func addSplitScore(_ measurement: SplitMeasurement, to score: inout SplitScore) {
        if measurement.preIndent == -1, measurement.preBlank == 0 {
            score.penalty += startOfFilePenalty
        }
        if measurement.endOfFile {
            score.penalty += endOfFilePenalty
        }

        let postBlank = measurement.indent == -1 ? 1 + measurement.postBlank : 0
        let totalBlank = measurement.preBlank + postBlank
        score.penalty += totalBlankWeight * totalBlank
        score.penalty += postBlankWeight * postBlank

        let indent = measurement.indent != -1 ? measurement.indent : measurement.postIndent
        let anyBlanks = totalBlank != 0
        score.effectiveIndent += indent

        if indent == -1 || measurement.preIndent == -1 {
            return
        }
        if indent > measurement.preIndent {
            score.penalty += anyBlanks ? relativeIndentWithBlankPenalty : relativeIndentPenalty
        } else if indent < measurement.preIndent {
            if measurement.postIndent != -1, measurement.postIndent > indent {
                score.penalty += anyBlanks ? relativeOutdentWithBlankPenalty : relativeOutdentPenalty
            } else {
                score.penalty += anyBlanks ? relativeDedentWithBlankPenalty : relativeDedentPenalty
            }
        }
    }

    private static func compareScores(_ lhs: SplitScore, _ rhs: SplitScore) -> Int {
        let indentComparison = (lhs.effectiveIndent > rhs.effectiveIndent ? 1 : 0)
            - (lhs.effectiveIndent < rhs.effectiveIndent ? 1 : 0)
        return indentWeight * indentComparison + (lhs.penalty - rhs.penalty)
    }
}
