import Foundation

struct DiffRowBlock {
    let id: String
    let rows: Range<Int>
    var preservesSelectionWhenReloaded = false
}

/// 表格按文件区间更新；相同行数只重载，行数变化合并成一次插入和删除。
struct DiffRowUpdatePlan {
    let removedRows: IndexSet
    let insertedRows: IndexSet
    let reloadedRows: IndexSet
    private let unchangedBlocks: [(old: Range<Int>, new: Range<Int>)]
    private let semanticRowMappings: [Int: IndexSet]

    init(
        previous: [DiffRowBlock],
        current: [DiffRowBlock],
        changedIDs: Set<String>,
        semanticRowMappings: [Int: IndexSet] = [:]
    ) {
        let previousIDs = previous.map(\.id)
        let currentIDs = current.map(\.id)
        let differences = currentIDs == previousIDs ? [] : Array(currentIDs.difference(from: previousIDs))
        var removedIDs = Set<String>()
        var insertedIDs = Set<String>()
        for difference in differences {
            switch difference {
            case let .remove(_, id, _): removedIDs.insert(id)
            case let .insert(_, id, _): insertedIDs.insert(id)
            }
        }
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        var removed = IndexSet()
        var inserted = IndexSet()
        var reloaded = IndexSet()
        var unchanged: [(old: Range<Int>, new: Range<Int>)] = []
        for block in previous {
            if removedIDs.contains(block.id) { removed.insert(integersIn: block.rows) }
        }
        for block in current {
            if insertedIDs.contains(block.id) { inserted.insert(integersIn: block.rows) }
            guard let old = previousByID[block.id] else { continue }
            let changed = changedIDs.contains(block.id) || old.rows.count != block.rows.count
            if !changed || (block.preservesSelectionWhenReloaded && old.rows.count == block.rows.count) {
                unchanged.append((old.rows, block.rows))
            }
            guard !removedIDs.contains(block.id), !insertedIDs.contains(block.id), changed else { continue }
            if old.rows.count == block.rows.count {
                reloaded.insert(integersIn: block.rows)
            } else {
                removed.insert(integersIn: old.rows)
                inserted.insert(integersIn: block.rows)
            }
        }
        // 移到其他位置的相同文件仍可映射选区，新增或删除文件没有旧行映射。
        for block in previous where currentByID[block.id] == nil {
            removed.insert(integersIn: block.rows)
        }
        for block in current where previousByID[block.id] == nil {
            inserted.insert(integersIn: block.rows)
        }
        removedRows = removed
        insertedRows = inserted
        reloadedRows = reloaded
        unchangedBlocks = unchanged
        self.semanticRowMappings = semanticRowMappings
    }

    func currentRow(for previousRow: Int) -> Int? {
        let rows = currentRows(for: previousRow)
        return rows.count == 1 ? rows.first : nil
    }

    /// split 的一行可能变成 unified 的两行，行选区要保留两个落点。
    func currentRows(for previousRow: Int) -> IndexSet {
        if let block = unchangedBlocks.first(where: { $0.old.contains(previousRow) }) {
            return IndexSet(integer: block.new.lowerBound + previousRow - block.old.lowerBound)
        }
        return semanticRowMappings[previousRow] ?? []
    }

    func preservesRows(in range: ClosedRange<Int>) -> Bool {
        let blocks = unchangedBlocks.filter { $0.old.overlaps(range.lowerBound..<(range.upperBound + 1)) }
            .sorted { $0.old.lowerBound < $1.old.lowerBound }
        guard let start = currentRow(for: range.lowerBound), let end = currentRow(for: range.upperBound),
              end - start == range.upperBound - range.lowerBound else { return false }
        var previousEnd = range.lowerBound
        var currentEnd = start
        for block in blocks {
            let lower = max(block.old.lowerBound, range.lowerBound)
            let upper = min(block.old.upperBound, range.upperBound + 1)
            let newLower = block.new.lowerBound + lower - block.old.lowerBound
            guard lower == previousEnd, newLower == currentEnd else { return false }
            previousEnd = upper
            currentEnd = newLower + upper - lower
        }
        return previousEnd == range.upperBound + 1
    }
}
