import AgentGitCore
import AppKit
import SwiftUI

enum DiffStackStatus: Hashable {
    case added
    case deleted
    case modified
    case renamed
    case untracked
    case conflicted
}

enum DiffStackMutationMode: Hashable {
    case working
    case staged

    var primaryAction: GitPendingSelectionAction {
        switch self {
        case .working: .stage
        case .staged: .unstage
        }
    }

    var fileActionTitle: String {
        switch self {
        case .working: "Stage"
        case .staged: "Unstage"
        }
    }

    var hunkActionTitle: String {
        switch self {
        case .working: "Stage Hunk"
        case .staged: "Unstage Hunk"
        }
    }
}

struct DiffStackFile: Identifiable, Hashable {
    let id: String
    let path: String
    let status: DiffStackStatus
    let statusLabel: String
    let isExpanded: Bool
    let isFocused: Bool
    let mutationMode: DiffStackMutationMode?
    let diff: GitFileDiff?
}

struct DiffStackGroup: Identifiable, Hashable {
    let id: String
    let title: String?
    let emptyMessage: String
    let isExpanded: Bool
    let files: [DiffStackFile]
}

/// 单个 `NSTableView` 承载整次评审的所有文件，展开只是插入行，不新建视图层级。
struct DiffStackView: NSViewRepresentable {
    let groups: [DiffStackGroup]
    let layout: DiffLayoutMode
    let scrollTarget: String?
    let scrollKey: ReviewStateKey
    let scrollStore: ReviewStateStore
    let onToggleFile: (String) -> Void
    let onToggleGroup: (String) -> Void
    let onFileAction: (String, GitPendingSelectionAction) -> Void
    let onSelectionAction: (String, Set<GitDiffLine.ID>, GitPendingSelectionAction) -> Void

    func makeNSView(context: Context) -> DiffStackScrollView {
        let scrollView = DiffStackScrollView()
        apply(to: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: DiffStackScrollView, context: Context) {
        apply(to: scrollView)
    }

    private func apply(to scrollView: DiffStackScrollView) {
        scrollView.onToggleFile = onToggleFile
        scrollView.onToggleGroup = onToggleGroup
        scrollView.onFileAction = onFileAction
        scrollView.onSelectionAction = onSelectionAction
        scrollView.bind(store: scrollStore, key: scrollKey)
        scrollView.display(groups: groups, layout: layout, scrollTarget: scrollTarget)
    }
}

final class DiffStackScrollView: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    private enum Metrics {
        static let lineHeight: CGFloat = 20
        static let hunkHeight: CGFloat = 26
        static let fileHeight: CGFloat = 38
        static let groupHeight: CGFloat = 30
        static let noteHeight: CGFloat = 30
    }

    private struct FileSection {
        let groupID: String
        let headerRow: Int
        let endRow: Int
        let file: DiffStackFile
    }

    private struct GroupSection {
        let headerRow: Int
        let endRow: Int
        let group: DiffStackGroup
    }

    var onToggleFile: ((String) -> Void)?
    var onToggleGroup: ((String) -> Void)?
    var onFileAction: ((String, GitPendingSelectionAction) -> Void)?
    var onSelectionAction: ((String, Set<GitDiffLine.ID>, GitPendingSelectionAction) -> Void)?

    private let tableView = DiffCopyingTableView()
    private let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("diff"))
    private let stickyClip = DiffStickyClipView()
    private let stickyGroupHeader = DiffGroupCellView()
    private let stickyFileHeader = DiffFileCellView()
    private var stickyGroupID: String?
    private var stickyFileID: String?
    private var isUpdatingSticky = false
    private var rows: [DiffStackRow] = []
    private var groupSections: [GroupSection] = []
    private var fileSections: [FileSection] = []
    private var hunkRowIndexes: [Int] = []
    private var groupRowIndexByID: [String: Int] = [:]
    private var fileRowIndexByID: [String: Int] = [:]
    private var renderToken: DiffStackToken?
    private var appliedScrollTarget: String?
    private var scrollStore: ReviewStateStore?
    private var scrollKey: ReviewStateKey?
    private var pendingRestoreOffset: CGFloat?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureTable()
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func layout() {
        super.layout()
        updateColumnWidth()
        updateStickyHeader()
    }

    override func scrollWheel(with event: NSEvent) {
        guard Self.shouldForwardScrollWheel(
            horizontalDelta: event.scrollingDeltaX,
            verticalDelta: event.scrollingDeltaY
        ) else {
            return
        }
        super.scrollWheel(with: event)
    }

    static func shouldForwardScrollWheel(
        horizontalDelta: CGFloat,
        verticalDelta: CGFloat
    ) -> Bool {
        abs(verticalDelta) >= abs(horizontalDelta)
    }

    /// 切换 worktree / context 时先落存旧位置，再把新位置排进待恢复。
    func bind(store: ReviewStateStore, key: ReviewStateKey) {
        scrollStore = store
        guard scrollKey != key else {
            return
        }
        if let previousKey = scrollKey, pendingRestoreOffset == nil {
            store.saveScrollOffset(contentView.bounds.minY, for: previousKey)
        }
        scrollKey = key
        appliedScrollTarget = nil
        let restored = store.scrollOffset(for: key)
        pendingRestoreOffset = restored > 0 ? restored : nil
        contentView.scroll(to: .zero)
        reflectScrolledClipView(contentView)
    }

    /// diff 是异步到的，文档会一路变高；够高之前反复重试，够高了才算恢复完成。
    private func restorePendingOffsetIfPossible() {
        guard let target = pendingRestoreOffset else {
            return
        }
        let maxOffset = max(0, tableView.bounds.height - contentView.bounds.height)
        guard maxOffset >= target else {
            return
        }
        contentView.scroll(to: NSPoint(x: 0, y: target))
        reflectScrolledClipView(contentView)
        pendingRestoreOffset = nil
        updateStickyHeader()
    }

    func display(
        groups: [DiffStackGroup],
        layout: DiffLayoutMode,
        scrollTarget: String?
    ) {
        let token = DiffStackToken(groups: groups, layout: layout)
        if token != renderToken {
            renderToken = token
            rebuildRows(groups: groups, layout: layout)
            updateColumnWidth()
            tableView.reloadData()
            stickyGroupID = nil
            stickyFileID = nil
            restorePendingOffsetIfPossible()
            updateStickyHeader()
        }

        guard scrollTarget != appliedScrollTarget else {
            return
        }
        appliedScrollTarget = scrollTarget
        if let scrollTarget {
            scroll(toFileID: scrollTarget)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        switch rows[row] {
        case let .group(group, count):
            let cell = reusableCell(DiffGroupCellView.self, identifier: DiffGroupCellView.identifier)
            cell.update(group: group, count: count)
            return cell
        case let .file(file):
            let cell = reusableCell(DiffFileCellView.self, identifier: DiffFileCellView.identifier)
            cell.update(file: file, actionHandler: onFileAction)
            return cell
        case let .hunk(header, fileID, lineIDs, mutationMode):
            let cell = reusableCell(DiffHunkCellView.self, identifier: DiffHunkCellView.identifier)
            cell.update(
                header: header,
                fileID: fileID,
                lineIDs: lineIDs,
                mutationMode: mutationMode,
                actionHandler: onSelectionAction
            )
            return cell
        case let .line(line, language, _, _):
            let cell = reusableCell(DiffLineCellView.self, identifier: DiffLineCellView.identifier)
            cell.update(line: line, language: language)
            return cell
        case let .sideBySide(pair, language, _, _):
            let cell = reusableCell(
                DiffSideBySideCellView.self,
                identifier: DiffSideBySideCellView.identifier
            )
            cell.update(pair: pair, language: language)
            return cell
        case let .note(text):
            let cell = reusableCell(DiffNoteCellView.self, identifier: DiffNoteCellView.identifier)
            cell.update(text: text)
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .group: Metrics.groupHeight
        case .file: Metrics.fileHeight
        case .hunk: Metrics.hunkHeight
        case .line, .sideBySide: Metrics.lineHeight
        case .note: Metrics.noteHeight
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        switch rows[row] {
        case .hunk, .line, .sideBySide: true
        case .group, .file, .note: false
        }
    }

    private func reusableCell<Cell: NSTableCellView>(
        _ type: Cell.Type,
        identifier: NSUserInterfaceItemIdentifier
    ) -> Cell {
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? Cell ?? Cell()
        cell.identifier = identifier
        return cell
    }

    private func rebuildRows(groups: [DiffStackGroup], layout: DiffLayoutMode) {
        var built: [DiffStackRow] = []
        var builtGroupSections: [GroupSection] = []
        var builtFileSections: [FileSection] = []
        var groupIndexByID: [String: Int] = [:]
        var fileIndexByID: [String: Int] = [:]
        built.reserveCapacity(Self.estimatedRowCount(for: groups))

        for group in groups {
            let groupHeaderRow: Int?
            if group.title != nil {
                groupHeaderRow = built.count
                groupIndexByID[group.id] = built.count
                built.append(.group(group, count: group.files.count))
            } else {
                groupHeaderRow = nil
            }
            guard !group.files.isEmpty else {
                built.append(.note(group.emptyMessage))
                if let groupHeaderRow {
                    builtGroupSections.append(
                        GroupSection(
                            headerRow: groupHeaderRow,
                            endRow: built.count,
                            group: group
                        )
                    )
                }
                continue
            }
            for file in group.files {
                let headerRow = built.count
                fileIndexByID[file.id] = headerRow
                built.append(.file(file))
                appendContent(of: file, layout: layout, into: &built)
                builtFileSections.append(
                    FileSection(
                        groupID: group.id,
                        headerRow: headerRow,
                        endRow: built.count,
                        file: file
                    )
                )
            }
            if let groupHeaderRow {
                builtGroupSections.append(
                    GroupSection(
                        headerRow: groupHeaderRow,
                        endRow: built.count,
                        group: group
                    )
                )
            }
        }

        rows = built
        groupSections = builtGroupSections
        fileSections = builtFileSections
        hunkRowIndexes = built.indices.filter { index in
            if case .hunk = built[index] {
                return true
            }
            return false
        }
        groupRowIndexByID = groupIndexByID
        fileRowIndexByID = fileIndexByID
    }

    private func appendContent(
        of file: DiffStackFile,
        layout: DiffLayoutMode,
        into rows: inout [DiffStackRow]
    ) {
        guard file.isExpanded else {
            return
        }
        guard let diff = file.diff else {
            rows.append(.note("Loading diff…"))
            return
        }
        guard !diff.hunks.isEmpty else {
            rows.append(.note(diff.state.note ?? "No textual changes"))
            return
        }

        let language = GitSyntaxLanguage(path: file.path)
        for hunk in diff.hunks {
            let changedLineIDs = Set(
                hunk.lines.filter { $0.kind == .addition || $0.kind == .deletion }.map(\.id)
            )
            rows.append(
                .hunk(
                    hunk.header,
                    fileID: file.id,
                    lineIDs: changedLineIDs,
                    mutationMode: file.mutationMode
                )
            )
            switch layout {
            case .unified:
                for line in hunk.lines {
                    rows.append(
                        .line(
                            line,
                            language,
                            fileID: file.id,
                            mutationMode: file.mutationMode
                        )
                    )
                }
            case .sideBySide:
                for pair in SideBySideDiffBuilder.pairs(hunk.lines) {
                    rows.append(
                        .sideBySide(
                            pair,
                            language,
                            fileID: file.id,
                            mutationMode: file.mutationMode
                        )
                    )
                }
            }
        }
    }

    private static func estimatedRowCount(for groups: [DiffStackGroup]) -> Int {
        groups.reduce(0) { total, group in
            total + 1 + group.files.reduce(0) { fileTotal, file in
                guard file.isExpanded, let diff = file.diff else {
                    return fileTotal + 1
                }
                return fileTotal + 1 + diff.hunks.reduce(diff.hunks.count) { count, hunk in
                    count + hunk.lines.count
                }
            }
        }
    }

    private func scroll(toFileID fileID: String) {
        guard let row = fileRowIndexByID[fileID] else {
            return
        }
        tableView.layoutSubtreeIfNeeded()
        let rect = tableView.rect(ofRow: row)
        let target = NSPoint(x: 0, y: rect.minY)
        contentView.scroll(to: target)
        reflectScrolledClipView(contentView)
        updateStickyHeader()
    }

    @discardableResult
    func moveHunk(by offset: Int) -> Bool {
        guard !hunkRowIndexes.isEmpty, offset != 0 else {
            return false
        }
        let anchorRow: Int
        if tableView.selectedRow >= 0 {
            anchorRow = tableView.selectedRow
        } else {
            anchorRow = max(
                -1,
                tableView.row(
                    at: NSPoint(x: 0, y: contentView.bounds.minY + 1)
                )
            )
        }

        let targetRow: Int
        if offset > 0 {
            targetRow = hunkRowIndexes.first(where: { $0 > anchorRow })
                ?? hunkRowIndexes[0]
        } else {
            targetRow = hunkRowIndexes.last(where: { $0 < anchorRow })
                ?? hunkRowIndexes[hunkRowIndexes.count - 1]
        }

        tableView.selectRowIndexes(
            IndexSet(integer: targetRow),
            byExtendingSelection: false
        )
        let stickyHeight = Metrics.groupHeight + Metrics.fileHeight
        let targetOffset = max(0, tableView.rect(ofRow: targetRow).minY - stickyHeight)
        let maxOffset = max(0, tableView.bounds.height - contentView.bounds.height)
        contentView.scroll(
            to: NSPoint(x: 0, y: min(targetOffset, maxOffset))
        )
        reflectScrolledClipView(contentView)
        updateStickyHeader()
        return true
    }

    private func configureTable() {
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        borderType = .noBorder
        hasHorizontalScroller = false
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        horizontalScrollElasticity = .none
        usesPredominantAxisScrolling = true

        tableColumn.minWidth = 0
        tableColumn.resizingMask = .autoresizingMask
        tableView.addTableColumn(tableColumn)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.style = .inset
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.intercellSpacing = .zero
        tableView.rowHeight = Metrics.lineHeight
        tableView.usesAutomaticRowHeights = false
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .textBackgroundColor
        tableView.focusRingType = .none
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = true
        tableView.selectionHighlightStyle = .regular
        tableView.copyTextProvider = { [weak self] selectedRows in
            self?.copyText(for: selectedRows) ?? ""
        }
        tableView.rowClickHandler = { [weak self] row in
            self?.handleClick(onRow: row) ?? false
        }
        tableView.dynamicMenuProvider = { [weak self] row, selectedRows in
            self?.contextMenu(clickedRow: row, selectedRows: selectedRows)
        }
        tableView.hunkNavigationHandler = { [weak self] offset in
            self?.moveHunk(by: offset) ?? false
        }
        documentView = tableView

        // 分组头与文件头共用一个裁剪容器，下一组 / 文件会自然把当前头推走。
        stickyClip.isHidden = true
        stickyGroupHeader.clipsToBounds = true
        stickyFileHeader.clipsToBounds = true
        stickyClip.addSubview(stickyFileHeader)
        stickyClip.addSubview(stickyGroupHeader)
        stickyGroupHeader.clickHandler = { [weak self] groupID in
            self?.handleStickyGroupClick(groupID: groupID)
        }
        stickyFileHeader.clickHandler = { [weak self] fileID in
            self?.handleStickyClick(fileID: fileID)
        }
        stickyFileHeader.actionHandler = { [weak self] fileID, action in
            self?.onFileAction?(fileID, action)
        }
        addSubview(stickyClip, positioned: .above, relativeTo: contentView)

        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewBoundsChanged),
            name: NSView.boundsDidChangeNotification,
            object: contentView
        )
    }

    @objc private func clipViewBoundsChanged() {
        if pendingRestoreOffset == nil, let scrollKey {
            scrollStore?.saveScrollOffset(contentView.bounds.minY, for: scrollKey)
        }
        updateStickyHeader()
    }

    /// NSScrollView 跟随 document view 翻转，这里 minY 就是视口顶边。
    private func updateStickyHeader() {
        guard !isUpdatingSticky else {
            return
        }
        isUpdatingSticky = true
        defer { isUpdatingSticky = false }

        let top = contentView.bounds.minY
        let groupSection = currentGroupSection(above: top)
        let groupVisibleHeight = stickyGroupVisibleHeight(
            for: groupSection,
            top: top
        )
        let fileTop = top + groupVisibleHeight
        var fileSection = currentFileSection(above: fileTop)
        if let groupSection {
            if fileSection?.groupID != groupSection.group.id {
                fileSection = nil
            }
        } else if !groupSections.isEmpty {
            fileSection = nil
        }
        let fileVisibleHeight = stickyFileVisibleHeight(
            for: fileSection,
            top: fileTop
        )
        let totalVisibleHeight = groupVisibleHeight + fileVisibleHeight
        guard totalVisibleHeight > 1 else {
            hideStickyHeaders()
            return
        }

        if groupVisibleHeight > 1, let groupSection {
            if stickyGroupID != groupSection.group.id {
                stickyGroupID = groupSection.group.id
                stickyGroupHeader.update(
                    group: groupSection.group,
                    count: groupSection.group.files.count
                )
            }
            stickyGroupHeader.isHidden = false
        } else {
            stickyGroupID = nil
            stickyGroupHeader.isHidden = true
        }

        if fileVisibleHeight > 1, let fileSection {
            if stickyFileID != fileSection.file.id {
                stickyFileID = fileSection.file.id
                stickyFileHeader.update(file: fileSection.file)
            }
            stickyFileHeader.isHidden = false
        } else {
            stickyFileID = nil
            stickyFileHeader.isHidden = true
        }

        let clipFrame = NSRect(
            x: contentView.frame.minX,
            y: contentView.frame.minY,
            width: contentView.frame.width,
            height: totalVisibleHeight
        )
        if stickyClip.frame != clipFrame {
            stickyClip.frame = clipFrame
        }
        let horizontalInset = max(0, (clipFrame.width - tableColumn.width) / 2)
        let groupFrame = NSRect(
            x: horizontalInset,
            y: groupVisibleHeight - Metrics.groupHeight,
            width: tableColumn.width,
            height: Metrics.groupHeight
        )
        if stickyGroupHeader.frame != groupFrame {
            stickyGroupHeader.frame = groupFrame
        }
        let fileFrame = NSRect(
            x: horizontalInset,
            y: groupVisibleHeight + fileVisibleHeight - Metrics.fileHeight,
            width: tableColumn.width,
            height: Metrics.fileHeight
        )
        if stickyFileHeader.frame != fileFrame {
            stickyFileHeader.frame = fileFrame
        }
        stickyClip.isHidden = false
    }

    private func hideStickyHeaders() {
        stickyGroupID = nil
        stickyFileID = nil
        stickyGroupHeader.isHidden = true
        stickyFileHeader.isHidden = true
        stickyClip.isHidden = true
    }

    private func currentGroupSection(above top: CGFloat) -> GroupSection? {
        var low = 0
        var high = groupSections.count - 1
        var found: GroupSection?
        while low <= high {
            let mid = (low + high) / 2
            if tableView.rect(ofRow: groupSections[mid].headerRow).minY <= top {
                found = groupSections[mid]
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }

    private func currentFileSection(above top: CGFloat) -> FileSection? {
        var low = 0
        var high = fileSections.count - 1
        var found: FileSection?
        while low <= high {
            let mid = (low + high) / 2
            if tableView.rect(ofRow: fileSections[mid].headerRow).minY <= top {
                found = fileSections[mid]
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }

    private func stickyGroupVisibleHeight(
        for section: GroupSection?,
        top: CGFloat
    ) -> CGFloat {
        guard let section,
              tableView.rect(ofRow: section.headerRow).minY < top else {
            return 0
        }
        return max(
            0,
            min(Metrics.groupHeight, sectionEndY(section.endRow) - top)
        )
    }

    private func stickyFileVisibleHeight(
        for section: FileSection?,
        top: CGFloat
    ) -> CGFloat {
        guard let section,
              section.endRow > section.headerRow + 1,
              tableView.rect(ofRow: section.headerRow).minY < top else {
            return 0
        }
        return max(
            0,
            min(Metrics.fileHeight, sectionEndY(section.endRow) - top)
        )
    }

    private func sectionEndY(_ endRow: Int) -> CGFloat {
        endRow < rows.count
            ? tableView.rect(ofRow: endRow).minY
            : tableView.bounds.maxY
    }

    private func handleStickyGroupClick(groupID: String) {
        if let row = groupRowIndexByID[groupID] {
            tableView.layoutSubtreeIfNeeded()
            contentView.scroll(to: NSPoint(x: 0, y: tableView.rect(ofRow: row).minY))
            reflectScrolledClipView(contentView)
        }
        onToggleGroup?(groupID)
    }

    private func handleStickyClick(fileID: String) {
        // 先把真实文件头滚回顶部，折叠后视口仍停在这个文件上。
        scroll(toFileID: fileID)
        onToggleFile?(fileID)
    }

    private func handleClick(onRow row: Int) -> Bool {
        guard rows.indices.contains(row) else {
            return false
        }
        switch rows[row] {
        case let .file(file):
            onToggleFile?(file.id)
            return true
        case let .group(group, _):
            onToggleGroup?(group.id)
            return true
        case .hunk, .line, .sideBySide, .note:
            return false
        }
    }

    func contextMenu(clickedRow: Int, selectedRows: IndexSet) -> NSMenu {
        let menu = NSMenu()
        let copyItem = NSMenuItem(
            title: "Copy Selected Lines",
            action: #selector(DiffCopyingTableView.copy(_:)),
            keyEquivalent: ""
        )
        copyItem.target = tableView
        menu.addItem(copyItem)

        guard rows.indices.contains(clickedRow) else {
            return menu
        }

        switch rows[clickedRow] {
        case let .file(file):
            guard let mode = file.mutationMode else {
                return menu
            }
            menu.addItem(.separator())
            addMenuItem(
                mode.fileActionTitle,
                command: .file(file.id, mode.primaryAction),
                to: menu
            )
            if mode == .working {
                addMenuItem("Discard File…", command: .file(file.id, .discard), to: menu)
            }

        case let .hunk(_, fileID, lineIDs, mutationMode):
            guard let mutationMode, !lineIDs.isEmpty else {
                return menu
            }
            menu.addItem(.separator())
            addMenuItem(
                mutationMode.hunkActionTitle,
                command: .selection(fileID, lineIDs, mutationMode.primaryAction),
                to: menu
            )
            if mutationMode == .working {
                addMenuItem(
                    "Discard Hunk…",
                    command: .selection(fileID, lineIDs, .discard),
                    to: menu
                )
            }

        case .line, .sideBySide:
            guard let selection = selectedChangedLines(
                clickedRow: clickedRow,
                selectedRows: selectedRows
            ) else {
                return menu
            }
            menu.addItem(.separator())
            let noun = selection.lineIDs.count == 1 ? "Line" : "Lines"
            switch selection.mode {
            case .working:
                addMenuItem(
                    "Stage Selected \(noun)",
                    command: .selection(selection.fileID, selection.lineIDs, .stage),
                    to: menu
                )
                addMenuItem(
                    "Discard Selected \(noun)…",
                    command: .selection(selection.fileID, selection.lineIDs, .discard),
                    to: menu
                )
            case .staged:
                addMenuItem(
                    "Unstage Selected \(noun)",
                    command: .selection(selection.fileID, selection.lineIDs, .unstage),
                    to: menu
                )
            }

        case .group, .note:
            break
        }
        return menu
    }

    private struct ChangedLineSelection {
        let fileID: String
        let lineIDs: Set<GitDiffLine.ID>
        let mode: DiffStackMutationMode
    }

    private func selectedChangedLines(
        clickedRow: Int,
        selectedRows: IndexSet
    ) -> ChangedLineSelection? {
        let targetRows = selectedRows.contains(clickedRow) ? selectedRows : IndexSet(integer: clickedRow)
        var fileID: String?
        var mode: DiffStackMutationMode?
        var lineIDs: Set<GitDiffLine.ID> = []

        for rowIndex in targetRows {
            guard rows.indices.contains(rowIndex) else {
                continue
            }
            let rowFileID: String
            let rowMode: DiffStackMutationMode?
            let rowLineIDs: Set<GitDiffLine.ID>
            switch rows[rowIndex] {
            case let .line(line, _, candidateFileID, candidateMode):
                rowFileID = candidateFileID
                rowMode = candidateMode
                rowLineIDs = line.kind == .addition || line.kind == .deletion ? [line.id] : []
            case let .sideBySide(pair, _, candidateFileID, candidateMode):
                rowFileID = candidateFileID
                rowMode = candidateMode
                rowLineIDs = Set(
                    [pair.old, pair.new].compactMap { line in
                        guard let line,
                              line.kind == .addition || line.kind == .deletion else {
                            return nil
                        }
                        return line.id
                    }
                )
            case .group, .file, .hunk, .note:
                continue
            }
            guard let rowMode, !rowLineIDs.isEmpty else {
                continue
            }
            if let fileID, fileID != rowFileID {
                return nil
            }
            if let mode, mode != rowMode {
                return nil
            }
            fileID = rowFileID
            mode = rowMode
            lineIDs.formUnion(rowLineIDs)
        }

        guard let fileID, let mode, !lineIDs.isEmpty else {
            return nil
        }
        return ChangedLineSelection(fileID: fileID, lineIDs: lineIDs, mode: mode)
    }

    private func addMenuItem(
        _ title: String,
        command: DiffMutationMenuCommand.Value,
        to menu: NSMenu
    ) {
        let item = NSMenuItem(
            title: title,
            action: #selector(runMenuMutation(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = DiffMutationMenuCommand(command)
        menu.addItem(item)
    }

    @objc private func runMenuMutation(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? DiffMutationMenuCommand else {
            return
        }
        switch command.value {
        case let .file(fileID, action):
            onFileAction?(fileID, action)
        case let .selection(fileID, lineIDs, action):
            onSelectionAction?(fileID, lineIDs, action)
        }
    }

    private func updateColumnWidth() {
        let viewportWidth = contentView.bounds.width
        // table 总宽等于 viewport；列宽由 AppKit 从总宽中扣除 inset style 的左右 padding。
        if tableView.frame.width != viewportWidth {
            tableView.setFrameSize(
                NSSize(width: viewportWidth, height: tableView.frame.height)
            )
        }
        tableView.sizeLastColumnToFit()
    }

    private func copyText(for selectedRows: IndexSet) -> String {
        selectedRows.compactMap { rowIndex in
            guard rows.indices.contains(rowIndex) else {
                return nil
            }
            switch rows[rowIndex] {
            case let .hunk(header, _, _, _):
                return header
            case let .line(line, _, _, _):
                return line.copyText
            case let .sideBySide(pair, _, _, _):
                let values = [pair.old?.copyText, pair.new?.copyText].compactMap { $0 }
                if values.count == 2, values[0] == values[1] {
                    return values[0]
                }
                return values.joined(separator: "\n")
            case .file, .group, .note:
                return nil
            }
        }.joined(separator: "\n")
    }
}

/// 只比较结构与 hunk 存储地址，避免每次 SwiftUI 更新都深比较上万行。
private struct DiffStackToken: Equatable {
    private struct Entry: Equatable {
        let id: String
        let groupID: String
        let groupTitle: String?
        let groupIsExpanded: Bool
        let statusLabel: String
        let path: String
        let isExpanded: Bool
        let isFocused: Bool
        let mutationMode: DiffStackMutationMode?
        let hunkStorageAddress: UInt
        let hunkCount: Int
        let state: GitFileDiffState?
        let hasDiff: Bool
    }

    private let entries: [Entry]
    private let emptyGroupIDs: [String]
    private let layout: DiffLayoutMode

    init(groups: [DiffStackGroup], layout: DiffLayoutMode) {
        var entries: [Entry] = []
        var emptyGroupIDs: [String] = []
        for group in groups {
            if group.files.isEmpty {
                emptyGroupIDs.append(group.id)
            }
            for file in group.files {
                let address = file.diff?.hunks.withUnsafeBufferPointer { buffer in
                    buffer.baseAddress.map { UInt(bitPattern: $0) } ?? 0
                } ?? 0
                entries.append(
                    Entry(
                        id: file.id,
                        groupID: group.id,
                        groupTitle: group.title,
                        groupIsExpanded: group.isExpanded,
                        statusLabel: file.statusLabel,
                        path: file.path,
                        isExpanded: file.isExpanded,
                        isFocused: file.isFocused,
                        mutationMode: file.mutationMode,
                        hunkStorageAddress: address,
                        hunkCount: file.diff?.hunks.count ?? 0,
                        state: file.diff?.state,
                        hasDiff: file.diff != nil
                    )
                )
            }
        }
        self.entries = entries
        self.emptyGroupIDs = emptyGroupIDs
        self.layout = layout
    }
}

private enum DiffStackRow {
    case group(DiffStackGroup, count: Int)
    case file(DiffStackFile)
    case hunk(
        String,
        fileID: String,
        lineIDs: Set<GitDiffLine.ID>,
        mutationMode: DiffStackMutationMode?
    )
    case line(
        GitDiffLine,
        GitSyntaxLanguage,
        fileID: String,
        mutationMode: DiffStackMutationMode?
    )
    case sideBySide(
        GitDiffLinePair,
        GitSyntaxLanguage,
        fileID: String,
        mutationMode: DiffStackMutationMode?
    )
    case note(String)
}

private final class DiffCopyingTableView: NSTableView {
    var copyTextProvider: ((IndexSet) -> String)?
    var rowClickHandler: ((Int) -> Bool)?
    var dynamicMenuProvider: ((Int, IndexSet) -> NSMenu?)?
    var hunkNavigationHandler: ((Int) -> Bool)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        if clickedRow >= 0, rowClickHandler?(clickedRow) == true {
            return
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let shortcutModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 48 {
            if shortcutModifiers.isEmpty, hunkNavigationHandler?(1) == true {
                return
            }
            if shortcutModifiers == .shift, hunkNavigationHandler?(-1) == true {
                return
            }
        }
        if shortcutModifiers == .command,
           event.charactersIgnoringModifiers == "c" {
            copy(nil)
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        guard clickedRow >= 0 else {
            return super.menu(for: event)
        }
        if !selectedRowIndexes.contains(clickedRow) {
            selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }
        return dynamicMenuProvider?(clickedRow, selectedRowIndexes) ?? super.menu(for: event)
    }

    @objc func copy(_ sender: Any?) {
        guard let text = copyTextProvider?(selectedRowIndexes), !text.isEmpty else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private final class DiffMutationMenuCommand: NSObject {
    enum Value {
        case file(String, GitPendingSelectionAction)
        case selection(String, Set<GitDiffLine.ID>, GitPendingSelectionAction)
    }

    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

/// ▶/▼ 文本字形在 Mac 上偏“网页感”，统一换成系统 disclosure 符号。
@MainActor
private func makeDisclosureImageView() -> NSImageView {
    let view = NSImageView()
    view.imageScaling = .scaleNone
    view.contentTintColor = .tertiaryLabelColor
    return view
}

@MainActor
private func disclosureImage(isExpanded: Bool) -> NSImage? {
    let name = isExpanded ? "chevron.down" : "chevron.right"
    let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
    return image?.withSymbolConfiguration(
        NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
    )
}

private final class DiffStickyClipView: NSView {
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        nil
    }
}

private final class DiffGroupCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("diff-group")

    var clickHandler: ((String) -> Void)?

    private let chevron = makeDisclosureImageView()
    private let label = DiffTextField(
        font: .systemFont(ofSize: 11, weight: .semibold),
        textColor: .secondaryLabelColor,
        alignment: .left,
        selectable: false
    )
    private var groupID = ""

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(chevron)
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let clickHandler else {
            super.mouseDown(with: event)
            return
        }
        clickHandler(groupID)
    }

    override func layout() {
        super.layout()
        chevron.frame = NSRect(x: 10, y: 8, width: 14, height: 14)
        label.frame = NSRect(x: 26, y: 7, width: max(0, bounds.width - 40), height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
    }

    func update(group: DiffStackGroup, count: Int) {
        groupID = group.id
        chevron.image = disclosureImage(isExpanded: group.isExpanded)
        label.stringValue = "\((group.title ?? "").uppercased())  ·  \(count)"
        toolTip = group.isExpanded
            ? "Collapse all \(count) files"
            : "Expand all \(count) files"
        needsLayout = true
        needsDisplay = true
    }
}

private final class DiffFileCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("diff-file")

    var clickHandler: ((String) -> Void)?
    var actionHandler: ((String, GitPendingSelectionAction) -> Void)?

    private let chevron = makeDisclosureImageView()
    private let status = DiffTextField(
        font: .monospacedSystemFont(ofSize: 11, weight: .bold),
        textColor: .secondaryLabelColor,
        alignment: .center,
        selectable: false
    )
    private let title = DiffTextField(
        font: .systemFont(ofSize: 12, weight: .regular),
        textColor: .labelColor,
        alignment: .left,
        selectable: false
    )
    private let stats = DiffTextField(
        font: .monospacedSystemFont(ofSize: 11, weight: .medium),
        textColor: .secondaryLabelColor,
        alignment: .right,
        selectable: false
    )
    private let primaryButton = NSButton(title: "", target: nil, action: nil)
    private let discardButton = NSButton(title: "Discard", target: nil, action: nil)
    private var isFocused = false
    private var fileID = ""
    private var mutationMode: DiffStackMutationMode?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(chevron)
        addSubview(status)
        addSubview(title)
        addSubview(stats)
        addSubview(primaryButton)
        addSubview(discardButton)
        configure(primaryButton, action: #selector(runPrimaryAction))
        configure(discardButton, action: #selector(runDiscardAction))
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// 表格内的行由 NSTableView 统一派发点击，只有吸顶实例会装 clickHandler。
    override func mouseDown(with event: NSEvent) {
        guard let clickHandler else {
            super.mouseDown(with: event)
            return
        }
        clickHandler(fileID)
    }

    override func layout() {
        super.layout()
        let statsWidth: CGFloat = 100
        let primaryWidth: CGFloat = mutationMode == nil ? 0 : 62
        let discardWidth: CGFloat = mutationMode == .working ? 62 : 0
        let actionSpacing: CGFloat = mutationMode == nil ? 0 : 4
        let actionsWidth = primaryWidth + discardWidth
            + (discardWidth > 0 ? actionSpacing : 0)
        let actionX = bounds.width - actionsWidth - 10
        chevron.frame = NSRect(x: 10, y: 12, width: 14, height: 15)
        status.frame = NSRect(x: 26, y: 12, width: 16, height: 15)
        title.frame = NSRect(
            x: 48,
            y: 11,
            width: max(0, bounds.width - 48 - statsWidth - actionsWidth - 24),
            height: 17
        )
        stats.frame = NSRect(
            x: actionX - statsWidth - 6,
            y: 12,
            width: statsWidth,
            height: 15
        )
        primaryButton.frame = NSRect(x: actionX, y: 8, width: primaryWidth, height: 22)
        discardButton.frame = NSRect(
            x: actionX + primaryWidth + actionSpacing,
            y: 8,
            width: discardWidth,
            height: 22
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
        if isFocused {
            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
            dirtyRect.fill()
            NSColor.controlAccentColor.setFill()
            NSRect(x: 0, y: 0, width: 3, height: bounds.height).fill()
        }
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        super.draw(dirtyRect)
    }

    func update(
        file: DiffStackFile,
        actionHandler: ((String, GitPendingSelectionAction) -> Void)? = nil
    ) {
        fileID = file.id
        isFocused = file.isFocused
        mutationMode = file.mutationMode
        self.actionHandler = actionHandler ?? self.actionHandler
        chevron.image = disclosureImage(isExpanded: file.isExpanded)
        status.stringValue = file.statusLabel
        status.textColor = Self.color(for: file.status)
        title.attributedStringValue = Self.titleText(path: file.path)
        stats.attributedStringValue = Self.statsText(for: file.diff)
        primaryButton.title = file.mutationMode?.fileActionTitle ?? ""
        primaryButton.isHidden = file.mutationMode == nil
        discardButton.isHidden = file.mutationMode != .working
        toolTip = file.path
        needsLayout = true
        needsDisplay = true
    }

    private func configure(_ button: NSButton, action: Selector) {
        button.target = self
        button.action = action
        button.bezelStyle = .inline
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .medium)
    }

    @objc private func runPrimaryAction() {
        guard let action = mutationMode?.primaryAction else {
            return
        }
        actionHandler?(fileID, action)
    }

    @objc private func runDiscardAction() {
        actionHandler?(fileID, .discard)
    }

    private static func titleText(path: String) -> NSAttributedString {
        let name = (path as NSString).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent
        let text = NSMutableAttributedString(
            string: name,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.labelColor
            ]
        )
        guard !parent.isEmpty else {
            return text
        }
        text.append(
            NSAttributedString(
                string: "  \(parent)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: NSColor.tertiaryLabelColor
                ]
            )
        )
        return text
    }

    private static func statsText(for diff: GitFileDiff?) -> NSAttributedString {
        guard let diff else {
            return NSAttributedString(
                string: "…",
                attributes: [.foregroundColor: NSColor.tertiaryLabelColor]
            )
        }
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        let text = NSMutableAttributedString()
        text.append(
            NSAttributedString(
                string: "+\(diff.addedLineCount)",
                attributes: [.font: font, .foregroundColor: NSColor.systemGreen]
            )
        )
        text.append(
            NSAttributedString(
                string: "  −\(diff.deletedLineCount)",
                attributes: [.font: font, .foregroundColor: NSColor.systemRed]
            )
        )
        return text
    }

    private static func color(for status: DiffStackStatus) -> NSColor {
        switch status {
        case .added, .untracked: .systemGreen
        case .deleted: .systemRed
        case .renamed: .systemBlue
        case .conflicted: .systemPurple
        case .modified: .systemOrange
        }
    }
}

private final class DiffNoteCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("diff-note")

    private let label = DiffTextField(
        font: .systemFont(ofSize: 11, weight: .regular),
        textColor: .secondaryLabelColor,
        alignment: .left,
        selectable: false
    )

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 48, y: 8, width: max(0, bounds.width - 60), height: 16)
    }

    func update(text: String) {
        label.stringValue = text
    }
}

private final class DiffHunkCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("diff-hunk")

    private let label = DiffTextField(
        font: .monospacedSystemFont(ofSize: 11.5, weight: .regular),
        textColor: .systemBlue,
        alignment: .left,
        selectable: false
    )
    private let primaryButton = NSButton(title: "", target: nil, action: nil)
    private let discardButton = NSButton(title: "Discard", target: nil, action: nil)
    private var fileID = ""
    private var lineIDs: Set<GitDiffLine.ID> = []
    private var mutationMode: DiffStackMutationMode?
    private var actionHandler: ((String, Set<GitDiffLine.ID>, GitPendingSelectionAction) -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(label)
        addSubview(primaryButton)
        addSubview(discardButton)
        configure(primaryButton, action: #selector(runPrimaryAction))
        configure(discardButton, action: #selector(runDiscardAction))
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        let primaryWidth: CGFloat = mutationMode == nil ? 0 : 88
        let discardWidth: CGFloat = mutationMode == .working ? 62 : 0
        let spacing: CGFloat = discardWidth > 0 ? 4 : 0
        let actionsWidth = primaryWidth + discardWidth + spacing
        label.frame = NSRect(
            x: 10,
            y: 4,
            width: max(0, bounds.width - actionsWidth - 28),
            height: max(0, bounds.height - 8)
        )
        let actionX = bounds.width - actionsWidth - 10
        primaryButton.frame = NSRect(x: actionX, y: 2, width: primaryWidth, height: 22)
        discardButton.frame = NSRect(
            x: actionX + primaryWidth + spacing,
            y: 2,
            width: discardWidth,
            height: 22
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemBlue.withAlphaComponent(0.08).setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
    }

    func update(
        header: String,
        fileID: String,
        lineIDs: Set<GitDiffLine.ID>,
        mutationMode: DiffStackMutationMode?,
        actionHandler: ((String, Set<GitDiffLine.ID>, GitPendingSelectionAction) -> Void)?
    ) {
        label.stringValue = header
        self.fileID = fileID
        self.lineIDs = lineIDs
        self.mutationMode = mutationMode
        self.actionHandler = actionHandler
        primaryButton.title = mutationMode?.hunkActionTitle ?? ""
        primaryButton.isHidden = mutationMode == nil || lineIDs.isEmpty
        discardButton.isHidden = mutationMode != .working || lineIDs.isEmpty
        toolTip = "Tab: Next Hunk  ·  Shift-Tab: Previous Hunk"
        needsLayout = true
    }

    private func configure(_ button: NSButton, action: Selector) {
        button.target = self
        button.action = action
        button.bezelStyle = .inline
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .medium)
    }

    @objc private func runPrimaryAction() {
        guard let action = mutationMode?.primaryAction else {
            return
        }
        actionHandler?(fileID, lineIDs, action)
    }

    @objc private func runDiscardAction() {
        actionHandler?(fileID, lineIDs, .discard)
    }
}

private final class DiffLineCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("diff-line")

    private let oldLineNumber = DiffTextField.lineNumber()
    private let newLineNumber = DiffTextField.lineNumber()
    private let marker = DiffTextField(
        font: .monospacedSystemFont(ofSize: 12.5, weight: .regular),
        textColor: .secondaryLabelColor,
        alignment: .center,
        selectable: false
    )
    private let content = DiffTextField(
        font: .monospacedSystemFont(ofSize: 12.5, weight: .regular),
        textColor: .labelColor,
        alignment: .left,
        selectable: false
    )
    private var kind: GitDiffLineKind = .context

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(oldLineNumber)
        addSubview(newLineNumber)
        addSubview(marker)
        addSubview(content)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        let lineNumberWidth: CGFloat = 56
        oldLineNumber.frame = NSRect(x: 0, y: 0, width: lineNumberWidth, height: bounds.height)
        newLineNumber.frame = NSRect(
            x: lineNumberWidth,
            y: 0,
            width: lineNumberWidth,
            height: bounds.height
        )
        marker.frame = NSRect(x: lineNumberWidth * 2, y: 0, width: 22, height: bounds.height)
        content.frame = NSRect(
            x: lineNumberWidth * 2 + 22,
            y: 0,
            width: max(0, bounds.width - lineNumberWidth * 2 - 34),
            height: bounds.height
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        backgroundColor.setFill()
        dirtyRect.fill()
        NSColor.controlBackgroundColor.withAlphaComponent(0.72).setFill()
        NSRect(x: 0, y: dirtyRect.minY, width: 112, height: dirtyRect.height).fill()
        super.draw(dirtyRect)
    }

    func update(line: GitDiffLine, language: GitSyntaxLanguage) {
        kind = line.kind
        oldLineNumber.stringValue = line.oldLineNumber.map(String.init) ?? ""
        newLineNumber.stringValue = line.newLineNumber.map(String.init) ?? ""
        marker.stringValue = markerText
        marker.textColor = markerColor
        content.attributedStringValue = Self.contentText(for: line, language: language)
        needsDisplay = true
    }

    /// 单行过长时 NSTextField 的排版会卡死；只截显示，复制仍是整行。
    /// 截断后行内区间的偏移不再可信，直接不上高亮。
    fileprivate static func contentText(
        for line: GitDiffLine,
        language: GitSyntaxLanguage
    ) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ]

        guard line.content.utf8.count <= maximumDisplayedColumns else {
            return NSAttributedString(
                string: String(line.content.prefix(maximumDisplayedColumns)) + " …",
                attributes: attributes
            )
        }

        let text = NSMutableAttributedString(
            string: line.content.isEmpty ? " " : line.content,
            attributes: attributes
        )
        applySyntaxHighlighting(to: text, line: line, language: language)
        guard !line.inlineRanges.isEmpty, let highlight = inlineHighlight(for: line.kind) else {
            return text
        }

        let limit = text.length
        for range in line.inlineRanges {
            let clamped = NSRange(
                location: min(range.location, limit),
                length: min(range.length, max(0, limit - range.location))
            )
            guard clamped.length > 0 else {
                continue
            }
            text.addAttribute(.backgroundColor, value: highlight, range: clamped)
        }
        return text
    }

    private static func applySyntaxHighlighting(
        to text: NSMutableAttributedString,
        line: GitDiffLine,
        language: GitSyntaxLanguage
    ) {
        guard line.kind != .metadata else {
            return
        }
        let limit = text.length
        for span in DiffSyntaxHighlighter.spans(in: line.content, language: language) {
            let range = NSRange(
                location: min(span.location, limit),
                length: min(span.length, max(0, limit - span.location))
            )
            guard range.length > 0 else {
                continue
            }
            text.addAttribute(.foregroundColor, value: syntaxColor(for: span.kind), range: range)
            if span.kind == .heading {
                text.addAttribute(
                    .font,
                    value: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold),
                    range: range
                )
            }
        }
    }

    private static func syntaxColor(for kind: GitSyntaxTokenKind) -> NSColor {
        switch kind {
        case .keyword: .systemPurple
        case .string: .systemRed
        case .number: .systemBlue
        case .comment: .systemGreen
        case .heading: .systemBlue
        }
    }

    private static func inlineHighlight(for kind: GitDiffLineKind) -> NSColor? {
        switch kind {
        case .addition: NSColor.systemGreen.withAlphaComponent(0.30)
        case .deletion: NSColor.systemRed.withAlphaComponent(0.30)
        case .context, .metadata: nil
        }
    }

    private static let maximumDisplayedColumns = 4_000

    private var markerText: String {
        switch kind {
        case .addition: "+"
        case .deletion: "−"
        case .metadata: "·"
        case .context: " "
        }
    }

    private var markerColor: NSColor {
        switch kind {
        case .addition: .systemGreen
        case .deletion: .systemRed
        case .metadata: .secondaryLabelColor
        case .context: .clear
        }
    }

    private var backgroundColor: NSColor {
        switch kind {
        case .addition: .systemGreen.withAlphaComponent(0.10)
        case .deletion: .systemRed.withAlphaComponent(0.10)
        case .metadata: .secondaryLabelColor.withAlphaComponent(0.05)
        case .context: .clear
        }
    }
}

private final class DiffSideBySideCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("diff-side-by-side")

    private let oldPane = DiffSideLinePane(side: .old)
    private let newPane = DiffSideLinePane(side: .new)

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(oldPane)
        addSubview(newPane)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        let dividerX = floor(bounds.width / 2)
        oldPane.frame = NSRect(x: 0, y: 0, width: dividerX, height: bounds.height)
        newPane.frame = NSRect(
            x: dividerX + 1,
            y: 0,
            width: max(0, bounds.width - dividerX - 1),
            height: bounds.height
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.separatorColor.setFill()
        let dividerX = floor(bounds.width / 2)
        NSRect(x: dividerX, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
    }

    func update(pair: GitDiffLinePair, language: GitSyntaxLanguage) {
        oldPane.update(line: pair.old, language: language)
        newPane.update(line: pair.new, language: language)
        needsLayout = true
        needsDisplay = true
    }
}

private final class DiffSideLinePane: NSView {
    enum Side {
        case old
        case new
    }

    private let side: Side
    private let lineNumber = DiffTextField.lineNumber()
    private let marker = DiffTextField(
        font: .monospacedSystemFont(ofSize: 12.5, weight: .regular),
        textColor: .secondaryLabelColor,
        alignment: .center,
        selectable: false
    )
    private let content = DiffTextField(
        font: .monospacedSystemFont(ofSize: 12.5, weight: .regular),
        textColor: .labelColor,
        alignment: .left,
        selectable: false
    )
    private var kind: GitDiffLineKind?

    override var isFlipped: Bool { true }

    init(side: Side) {
        self.side = side
        super.init(frame: .zero)
        addSubview(lineNumber)
        addSubview(marker)
        addSubview(content)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        let lineNumberWidth: CGFloat = 56
        let markerWidth: CGFloat = 22
        lineNumber.frame = NSRect(x: 0, y: 0, width: lineNumberWidth, height: bounds.height)
        marker.frame = NSRect(
            x: lineNumberWidth,
            y: 0,
            width: markerWidth,
            height: bounds.height
        )
        content.frame = NSRect(
            x: lineNumberWidth + markerWidth,
            y: 0,
            width: max(0, bounds.width - lineNumberWidth - markerWidth - 8),
            height: bounds.height
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        backgroundColor.setFill()
        dirtyRect.fill()
        NSColor.controlBackgroundColor.withAlphaComponent(0.72).setFill()
        NSRect(x: 0, y: dirtyRect.minY, width: 56, height: dirtyRect.height).fill()
        super.draw(dirtyRect)
    }

    func update(line: GitDiffLine?, language: GitSyntaxLanguage) {
        kind = line?.kind
        guard let line else {
            lineNumber.stringValue = ""
            marker.stringValue = ""
            content.stringValue = ""
            needsDisplay = true
            return
        }

        switch side {
        case .old:
            lineNumber.stringValue = line.oldLineNumber.map(String.init) ?? ""
        case .new:
            lineNumber.stringValue = line.newLineNumber.map(String.init) ?? ""
        }
        marker.stringValue = markerText
        marker.textColor = markerColor
        content.attributedStringValue = DiffLineCellView.contentText(
            for: line,
            language: language
        )
        needsDisplay = true
    }

    private var markerText: String {
        guard let kind else {
            return ""
        }
        return switch (side, kind) {
        case (.old, .deletion): "−"
        case (.new, .addition): "+"
        case (_, .metadata): "·"
        case (_, .context), (.old, .addition), (.new, .deletion): ""
        }
    }

    private var markerColor: NSColor {
        guard let kind else {
            return .clear
        }
        return switch kind {
        case .addition: .systemGreen
        case .deletion: .systemRed
        case .metadata: .secondaryLabelColor
        case .context: .clear
        }
    }

    private var backgroundColor: NSColor {
        guard let kind else {
            return .controlBackgroundColor.withAlphaComponent(0.24)
        }
        return switch kind {
        case .addition: .systemGreen.withAlphaComponent(0.10)
        case .deletion: .systemRed.withAlphaComponent(0.10)
        case .metadata: .secondaryLabelColor.withAlphaComponent(0.05)
        case .context: .clear
        }
    }
}

private extension GitDiffLine {
    var copyText: String {
        let prefix: String
        switch kind {
        case .addition: prefix = "+"
        case .deletion: prefix = "-"
        case .context: prefix = " "
        case .metadata: prefix = ""
        }
        return prefix + content
    }
}

private final class DiffTextField: NSTextField {
    init(
        font: NSFont,
        textColor: NSColor,
        alignment: NSTextAlignment,
        selectable: Bool
    ) {
        super.init(frame: .zero)
        self.font = font
        self.textColor = textColor
        self.alignment = alignment
        isEditable = false
        isSelectable = selectable
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        lineBreakMode = .byClipping
        maximumNumberOfLines = 1
        usesSingleLineMode = true
        cell?.wraps = false
        cell?.isScrollable = false
    }

    required init?(coder: NSCoder) {
        nil
    }

    static func lineNumber() -> DiffTextField {
        DiffTextField(
            font: .monospacedSystemFont(ofSize: 11.5, weight: .regular),
            textColor: .tertiaryLabelColor,
            alignment: .right,
            selectable: false
        )
    }
}
