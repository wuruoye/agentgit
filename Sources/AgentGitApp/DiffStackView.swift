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

enum DiffStackFileUtilityAction: Hashable {
    case openFile
    case openInVisualStudioCode
    case revealInFinder
    case copyRelativePath
    case copyAbsolutePath
}

struct DiffStackContextGap: Identifiable, Hashable {
    let id: String
    let hiddenLineCount: Int
    let revealedLines: [GitDiffLine]
    let nextHunkAnchorID: String?
    let contextRenderID: UInt64?
}

enum DiffContextGapBuilder {
    private struct NumberedContextLine {
        let lineNumber: Int
        let line: GitDiffLine
    }

    static func gaps(
        fileID: String,
        compactDiff: GitFileDiff,
        contextSourceDiff: GitFileDiff?,
        revealedLineCountByGapID: [String: Int],
        revealsWholeFile: Bool = false
    ) -> [DiffStackContextGap] {
        guard let firstHunk = compactDiff.hunks.first,
              let lastHunk = compactDiff.hunks.last else {
            return []
        }
        var sourceLines = contextSourceDiff?.hunks
            .flatMap(\.lines)
            .compactMap { line -> NumberedContextLine? in
                guard line.kind == .context,
                      let lineNumber = line.newLineNumber else {
                    return nil
                }
                return NumberedContextLine(lineNumber: lineNumber, line: line)
            } ?? []
        let contextRenderID = contextSourceDiff?.renderID
        if zip(sourceLines, sourceLines.dropFirst()).contains(where: {
            $0.lineNumber > $1.lineNumber
        }) {
            sourceLines.sort { $0.lineNumber < $1.lineNumber }
        }
        var gaps: [DiffStackContextGap] = []

        if revealsWholeFile {
            let revealedLines = contextLines(
                in: sourceLines,
                from: nil,
                to: firstHunk.newStart
            )
            if !revealedLines.isEmpty {
                gaps.append(
                    DiffStackContextGap(
                        id: "\(fileID):context:start->\(firstHunk.id)",
                        hiddenLineCount: 0,
                        revealedLines: revealedLines,
                        nextHunkAnchorID: hunkAnchorID(
                            fileID: fileID,
                            hunkID: firstHunk.id
                        ),
                        contextRenderID: contextRenderID
                    )
                )
            }
        }

        gaps.append(contentsOf: zip(compactDiff.hunks, compactDiff.hunks.dropFirst()).compactMap {
            previousHunk, nextHunk in
            let gapStart = previousHunk.newStart + previousHunk.newCount
            let gapEnd = nextHunk.newStart
            let totalLineCount = gapEnd - gapStart
            guard totalLineCount > 0 else {
                return nil
            }

            let gapID = "\(fileID):context:\(previousHunk.id)->\(nextHunk.id)"
            let requestedLineCount = revealsWholeFile
                ? totalLineCount
                : min(totalLineCount, revealedLineCountByGapID[gapID] ?? 0)
            let revealedStart = gapEnd - requestedLineCount
            let revealedLines = contextLines(
                in: sourceLines,
                from: revealedStart,
                to: gapEnd
            )
            return DiffStackContextGap(
                id: gapID,
                hiddenLineCount: totalLineCount - revealedLines.count,
                revealedLines: revealedLines,
                nextHunkAnchorID: hunkAnchorID(fileID: fileID, hunkID: nextHunk.id),
                contextRenderID: contextRenderID
            )
        })

        if revealsWholeFile {
            let trailingStart = lastHunk.newStart + lastHunk.newCount
            let revealedLines = contextLines(
                in: sourceLines,
                from: trailingStart,
                to: nil
            )
            if !revealedLines.isEmpty {
                gaps.append(
                    DiffStackContextGap(
                        id: "\(fileID):context:\(lastHunk.id)->end",
                        hiddenLineCount: 0,
                        revealedLines: revealedLines,
                        nextHunkAnchorID: nil,
                        contextRenderID: contextRenderID
                    )
                )
            }
        }

        return gaps
    }

    private static func contextLines(
        in lines: [NumberedContextLine],
        from lowerLineNumber: Int?,
        to upperLineNumber: Int?
    ) -> [GitDiffLine] {
        let lowerIndex = lowerLineNumber.map { lowerBound(in: lines, for: $0) } ?? 0
        let upperIndex = upperLineNumber.map { lowerBound(in: lines, for: $0) } ?? lines.count
        guard lowerIndex < upperIndex else {
            return []
        }
        return lines[lowerIndex..<upperIndex].map(\.line)
    }

    private static func lowerBound(
        in lines: [NumberedContextLine],
        for lineNumber: Int
    ) -> Int {
        var lower = 0
        var upper = lines.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if lines[middle].lineNumber < lineNumber {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }
}

private func hunkAnchorID(fileID: String, hunkID: GitDiffHunk.ID) -> String {
    "\(fileID):hunk:\(hunkID)"
}

struct DiffStackFile: Identifiable, Hashable {
    let id: String
    let path: String
    let originalPath: String?
    let status: DiffStackStatus
    let statusLabel: String
    let isExpanded: Bool
    let isFocused: Bool
    let isReviewed: Bool
    let showsWholeFile: Bool
    let isLoadingWholeFile: Bool
    let canToggleWholeFile: Bool
    let canOpenWorkingFile: Bool
    let canOpenInVisualStudioCode: Bool
    let canApplyPrimaryAction: Bool
    let canDiscard: Bool
    let isMutationEnabled: Bool
    let mutationSnapshotID: DiffReviewSnapshotID?
    let contextGaps: [DiffStackContextGap]
    let mutationMode: DiffStackMutationMode?
    let diff: GitFileDiff?
    let imageDiff: GitImageDiff?
}

struct DiffStackGroup: Identifiable, Hashable {
    let id: String
    let title: String?
    let emptyMessage: String
    let isExpanded: Bool
    let files: [DiffStackFile]
}

struct DiffStackCommand: Equatable {
    enum Action: Equatable {
        case requestFileDiscard(String)
    }

    let id: UInt64
    let action: Action
}

/// 单个 `NSTableView` 承载整次评审的所有文件，展开只是插入行，不新建视图层级。
struct DiffStackView: NSViewRepresentable {
    let groups: [DiffStackGroup]
    let layout: DiffLayoutMode
    let scrollTarget: String?
    let scrollKey: ReviewStateKey
    let scrollStore: ReviewStateStore
    let isApplicationActive: Bool
    let loadingMessage: String
    let mutationActionsEnabled: Bool
    let command: DiffStackCommand?
    let onFocusFile: (String) -> Void
    let onToggleFile: (String) -> Void
    let onToggleGroup: (String) -> Void
    let onToggleReviewed: (String) -> Void
    let onToggleWholeFile: (String) -> Void
    let onExpandContext: (String, String) -> Void
    let onFileUtilityAction: (String, DiffStackFileUtilityAction) -> Void
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
        scrollView.onFocusFile = onFocusFile
        scrollView.onToggleFile = onToggleFile
        scrollView.onToggleGroup = onToggleGroup
        scrollView.onToggleReviewed = onToggleReviewed
        scrollView.onToggleWholeFile = onToggleWholeFile
        scrollView.onExpandContext = onExpandContext
        scrollView.onFileUtilityAction = onFileUtilityAction
        scrollView.onFileAction = onFileAction
        scrollView.onSelectionAction = onSelectionAction
        scrollView.bind(store: scrollStore, key: scrollKey)
        scrollView.isApplicationActive = isApplicationActive
        scrollView.loadingMessage = loadingMessage
        scrollView.mutationActionsEnabled = mutationActionsEnabled
        scrollView.display(groups: groups, layout: layout, scrollTarget: scrollTarget)
        scrollView.perform(command)
    }
}

final class DiffStackScrollView: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    private enum Metrics {
        static let lineHeight: CGFloat = 20
        static let hunkHeight: CGFloat = 24
        static let imageHeight: CGFloat = 360
        static let contextEdgeHeight: CGFloat = 14
        static let fileContextToggleHeight: CGFloat = 28
        static let fileHeight: CGFloat = 32
        static let groupHeight: CGFloat = 28
        static let noteHeight: CGFloat = 30
        static let unifiedCodeLeading: CGFloat = 134
        static let unifiedCodeTrailing: CGFloat = 12
        static let sideCodeLeading: CGFloat = 78
        static let sideCodeTrailing: CGFloat = 8
        static let maximumDisplayedColumns = 4_000
        static let codeCharacterWidth = ("M" as NSString).size(
            withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
            ]
        ).width
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
    var onFocusFile: ((String) -> Void)?
    var onToggleGroup: ((String) -> Void)?
    var onToggleReviewed: ((String) -> Void)?
    var onToggleWholeFile: ((String) -> Void)?
    var onExpandContext: ((String, String) -> Void)?
    var onFileUtilityAction: ((String, DiffStackFileUtilityAction) -> Void)?
    var onFileAction: ((String, GitPendingSelectionAction) -> Void)?
    var onSelectionAction: ((String, Set<GitDiffLine.ID>, GitPendingSelectionAction) -> Void)?
    var isApplicationActive = true {
        didSet {
            guard isApplicationActive != oldValue else {
                return
            }
            updateVisibleImagePreviews()
        }
    }
    var mutationActionsEnabled = true
    var loadingMessage = "Loading diff…"

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
    private var hunkRowIndexByAnchorID: [String: Int] = [:]
    private var groupRowIndexByID: [String: Int] = [:]
    private var fileRowIndexByID: [String: Int] = [:]
    private var fileSectionIndexByID: [String: Int] = [:]
    private var renderToken: DiffStackToken?
    private var filePresentationToken: DiffStackFilePresentationToken?
    private(set) var rowRebuildCount = 0
    private var appliedScrollTarget: String?
    private var scrollStore: ReviewStateStore?
    private var scrollKey: ReviewStateKey?
    private var pendingRestoreOffset: CGFloat?
    private var pendingHunkAnchor: PendingHunkAnchor?
    private var pendingCodeAnchor: PendingCodeAnchor?
    private var layoutMode: DiffLayoutMode = .sideBySide
    private var maximumCodeColumnCountByHunkID: [String: Int] = [:]
    private var codeContentWidthByHunkID: [String: CGFloat] = [:]
    private var codeHorizontalOffsetByHunkID: [String: CGFloat] = [:]
    private var appliedViewportWidth: CGFloat?
    private var appliedCommandID: UInt64?

    private struct PendingHunkAnchor {
        let anchorID: String
        let viewportY: CGFloat
    }

    private struct PendingCodeAnchor {
        let fileID: String
        let oldLineNumber: Int?
        let newLineNumber: Int?
        let viewportY: CGFloat
        let targetWholeFileState: Bool
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: NSView.noIntrinsicMetric
        )
    }

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
        if !Self.shouldForwardScrollWheel(
            horizontalDelta: event.scrollingDeltaX,
            verticalDelta: event.scrollingDeltaY
        ) {
            let tablePoint = tableView.convert(event.locationInWindow, from: nil)
            scrollCodeHorizontally(
                by: event.scrollingDeltaX,
                atTablePoint: tablePoint
            )
            return
        }
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
        appliedCommandID = nil
        pendingHunkAnchor = nil
        pendingCodeAnchor = nil
        codeHorizontalOffsetByHunkID = [:]
        let restored = store.scrollOffset(for: key)
        pendingRestoreOffset = restored > 0 ? restored : nil
        contentView.scroll(to: .zero)
        reflectScrolledClipView(contentView)
    }

    func perform(_ command: DiffStackCommand?) {
        guard let command, command.id != appliedCommandID else {
            return
        }
        appliedCommandID = command.id
        switch command.action {
        case let .requestFileDiscard(fileID):
            _ = requestFileDiscard(fileID: fileID)
        }
    }

    @discardableResult
    func requestFileDiscard(fileID: String) -> Bool {
        guard mutationActionsEnabled,
              let row = fileRowIndexByID[fileID],
              rows.indices.contains(row),
              case let .file(file) = rows[row],
              file.mutationMode == .working,
              file.canDiscard,
              file.isMutationEnabled else {
            return false
        }
        focusFile(fileID)
        scroll(toFileID: fileID)
        tableView.layoutSubtreeIfNeeded()
        guard let cell = tableView.view(
            atColumn: 0,
            row: row,
            makeIfNecessary: true
        ) as? DiffFileCellView else {
            return false
        }
        return cell.requestDiscardAction()
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
        let nextFilePresentationToken = DiffStackFilePresentationToken(groups: groups)
        if token != renderToken {
            if layoutMode != layout {
                codeHorizontalOffsetByHunkID = [:]
            }
            layoutMode = layout
            renderToken = token
            filePresentationToken = nextFilePresentationToken
            rebuildRows(groups: groups, layout: layout)
            updateColumnWidth(force: true)
            tableView.reloadData()
            stickyGroupID = nil
            stickyFileID = nil
            restorePendingCodeAnchor(groups: groups)
            restorePendingHunkAnchorIfPossible()
            restorePendingOffsetIfPossible()
            updateStickyHeader()
        } else if let filePresentationToken,
                  nextFilePresentationToken != filePresentationToken {
            let changedFileIDs = nextFilePresentationToken.changedFileIDs(
                from: filePresentationToken
            )
            self.filePresentationToken = nextFilePresentationToken
            updateFilePresentation(
                groups: groups,
                changedFileIDs: changedFileIDs
            )
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
            cell.update(
                file: file,
                reviewHandler: { [weak self] fileID in
                    self?.focusFile(fileID)
                    self?.onToggleReviewed?(fileID)
                },
                wholeFileHandler: { [weak self] fileID in
                    self?.handleWholeFileToggle(fileID: fileID)
                },
                actionHandler: { [weak self] fileID, action in
                    self?.focusFile(fileID)
                    self?.onFileAction?(fileID, action)
                },
                menuHandler: { [weak self] fileID in
                    self?.contextMenu(forFileID: fileID)
                }
            )
            return cell
        case let .hunk(hunk):
            let cell = reusableCell(DiffHunkCellView.self, identifier: DiffHunkCellView.identifier)
            cell.update(
                hunk: hunk,
                wholeFileHandler: { [weak self] fileID in
                    self?.handleWholeFileToggle(fileID: fileID)
                },
                actionHandler: { [weak self] fileID, lineIDs, action in
                    self?.focusFile(fileID)
                    self?.onSelectionAction?(fileID, lineIDs, action)
                }
            )
            return cell
        case let .contextEdge(gap, fileID):
            let cell = reusableCell(
                DiffContextEdgeCellView.self,
                identifier: DiffContextEdgeCellView.identifier
            )
            cell.update(
                gap: gap,
                fileID: fileID,
                expandHandler: { [weak self] fileID, gap in
                    self?.handleContextExpansion(fileID: fileID, gap: gap)
                }
            )
            return cell
        case let .fileContextToggle(fileID, showsWholeFile, isLoading):
            let cell = reusableCell(
                DiffFileContextToggleCellView.self,
                identifier: DiffFileContextToggleCellView.identifier
            )
            cell.update(
                fileID: fileID,
                showsWholeFile: showsWholeFile,
                isLoading: isLoading,
                toggleHandler: { [weak self] fileID in
                    self?.handleWholeFileToggle(fileID: fileID)
                }
            )
            return cell
        case let .line(line, language, _, hunkID, _):
            let cell = reusableCell(DiffLineCellView.self, identifier: DiffLineCellView.identifier)
            cell.update(line: line, language: language)
            cell.updateCodeViewport(
                horizontalOffset: codeHorizontalOffsetByHunkID[hunkID] ?? 0,
                contentWidth: codeContentWidth(for: hunkID)
            )
            return cell
        case let .sideBySide(pair, language, _, hunkID, _):
            let cell = reusableCell(
                DiffSideBySideCellView.self,
                identifier: DiffSideBySideCellView.identifier
            )
            cell.update(pair: pair, language: language)
            cell.updateCodeViewport(
                horizontalOffset: codeHorizontalOffsetByHunkID[hunkID] ?? 0,
                contentWidth: codeContentWidth(for: hunkID)
            )
            return cell
        case let .image(imageDiff):
            let cell = reusableCell(
                DiffImageCellView.self,
                identifier: DiffImageCellView.identifier
            )
            cell.setApplicationActive(isApplicationActive)
            cell.update(imageDiff: imageDiff)
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
        case .contextEdge: Metrics.contextEdgeHeight
        case .fileContextToggle: Metrics.fileContextToggleHeight
        case .line, .sideBySide: Metrics.lineHeight
        case .image: Metrics.imageHeight
        case .note: Metrics.noteHeight
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        switch rows[row] {
        case .hunk, .line, .sideBySide: true
        case .group, .file, .fileContextToggle, .contextEdge, .image, .note: false
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
        rowRebuildCount += 1
        var built: [DiffStackRow] = []
        var builtGroupSections: [GroupSection] = []
        var builtFileSections: [FileSection] = []
        var groupIndexByID: [String: Int] = [:]
        var fileIndexByID: [String: Int] = [:]
        var knownHunkIDs = Set<String>()
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
                if let diff = file.diff {
                    for hunk in diff.hunks {
                        knownHunkIDs.insert(
                            hunkAnchorID(fileID: file.id, hunkID: hunk.id)
                        )
                    }
                }
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
        maximumCodeColumnCountByHunkID = Self.maximumCodeColumnCountByHunkID(in: built)
        codeContentWidthByHunkID = maximumCodeColumnCountByHunkID.mapValues { columnCount in
            ceil(CGFloat(columnCount) * Metrics.codeCharacterWidth)
        }
        codeHorizontalOffsetByHunkID = codeHorizontalOffsetByHunkID.filter {
            knownHunkIDs.contains($0.key)
        }
        groupSections = builtGroupSections
        fileSections = builtFileSections
        hunkRowIndexes = built.indices.filter { index in
            if case .hunk = built[index] {
                return true
            }
            return false
        }
        hunkRowIndexByAnchorID = Dictionary(
            uniqueKeysWithValues: built.indices.compactMap { index in
                guard case let .hunk(hunk) = built[index] else {
                    return nil
                }
                return (hunk.anchorID, index)
            }
        )
        groupRowIndexByID = groupIndexByID
        fileRowIndexByID = fileIndexByID
        var sectionIndexByID: [String: Int] = [:]
        for index in builtFileSections.indices {
            sectionIndexByID[builtFileSections[index].file.id] = index
        }
        fileSectionIndexByID = sectionIndexByID
    }

    private func updateFilePresentation(
        groups: [DiffStackGroup],
        changedFileIDs: Set<String>
    ) {
        guard !changedFileIDs.isEmpty else {
            return
        }
        let filesByID = Dictionary(
            uniqueKeysWithValues: groups.flatMap(\.files).map { ($0.id, $0) }
        )
        var changedRows = IndexSet()
        for fileID in changedFileIDs {
            guard let updated = filesByID[fileID] else {
                continue
            }
            if let rowIndex = fileRowIndexByID[fileID] {
                rows[rowIndex] = .file(updated)
                changedRows.insert(rowIndex)
            }
            if let sectionIndex = fileSectionIndexByID[fileID] {
                let section = fileSections[sectionIndex]
                fileSections[sectionIndex] = FileSection(
                    groupID: section.groupID,
                    headerRow: section.headerRow,
                    endRow: section.endRow,
                    file: updated
                )
            }
        }
        if !changedRows.isEmpty {
            tableView.reloadData(
                forRowIndexes: changedRows,
                columnIndexes: IndexSet(integer: 0)
            )
        }
        if let stickyFileID,
           changedFileIDs.contains(stickyFileID),
           let updated = filesByID[stickyFileID] {
            stickyFileHeader.update(file: updated)
        }
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
            rows.append(.note(loadingMessage))
            return
        }
        if file.canToggleWholeFile || file.isLoadingWholeFile {
            rows.append(
                .fileContextToggle(
                    fileID: file.id,
                    showsWholeFile: file.showsWholeFile,
                    isLoading: file.isLoadingWholeFile
                )
            )
        }
        if let imageDiff = file.imageDiff {
            rows.append(.image(imageDiff))
            return
        }
        guard !diff.hunks.isEmpty else {
            rows.append(.note(diff.state.note ?? "No textual changes"))
            return
        }

        let language = GitSyntaxLanguage(path: file.path)
        let granularMutationMode = file.status == .conflicted
            ? nil
            : file.mutationMode
        let gapsByNextHunkAnchorID = Dictionary(
            uniqueKeysWithValues: file.contextGaps.compactMap { gap in
                gap.nextHunkAnchorID.map { ($0, gap) }
            }
        )
        let trailingGaps = file.contextGaps.filter { $0.nextHunkAnchorID == nil }
        for hunk in diff.hunks {
            let anchorID = hunkAnchorID(fileID: file.id, hunkID: hunk.id)
            let gap = gapsByNextHunkAnchorID[anchorID]
            if let gap {
                if gap.hiddenLineCount > 0 {
                    rows.append(.contextEdge(gap, fileID: file.id))
                }
                appendContextLines(
                    gap.revealedLines,
                    language: language,
                    file: file,
                    hunkID: anchorID,
                    layout: layout,
                    into: &rows
                )
            }
            let changedLineIDs = Set(
                hunk.lines.filter { $0.kind == .addition || $0.kind == .deletion }.map(\.id)
            )
            rows.append(
                .hunk(
                    DiffStackHunkRow(
                        anchorID: anchorID,
                        title: Self.hunkTitle(hunk),
                        location: Self.hunkLocation(hunk),
                        rawHeader: hunk.header,
                        layout: layout,
                        fileID: file.id,
                        lineIDs: changedLineIDs,
                        mutationMode: granularMutationMode,
                        isMutationEnabled: file.isMutationEnabled,
                        mutationSnapshotID: file.mutationSnapshotID,
                        showsWholeFile: file.showsWholeFile,
                        isLoadingWholeFile: file.isLoadingWholeFile,
                        canToggleWholeFile: file.canToggleWholeFile
                    )
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
                            hunkID: anchorID,
                            mutationMode: granularMutationMode
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
                            hunkID: anchorID,
                            mutationMode: granularMutationMode
                        )
                    )
                }
            }
        }
        let trailingHunkID = diff.hunks.last.map {
            hunkAnchorID(fileID: file.id, hunkID: $0.id)
        }
        for gap in trailingGaps {
            guard let trailingHunkID else {
                continue
            }
            if gap.hiddenLineCount > 0 {
                rows.append(.contextEdge(gap, fileID: file.id))
            }
            appendContextLines(
                gap.revealedLines,
                language: language,
                file: file,
                hunkID: trailingHunkID,
                layout: layout,
                into: &rows
            )
        }
    }

    private static func hunkTitle(_ hunk: GitDiffHunk) -> String {
        if let sectionHeading = hunk.sectionHeading, !sectionHeading.isEmpty {
            return sectionHeading
        }
        let oldRange = lineRange(start: hunk.oldStart, count: hunk.oldCount)
        let newRange = lineRange(start: hunk.newStart, count: hunk.newCount)
        return "Lines \(oldRange) → \(newRange)"
    }

    private static func hunkLocation(_ hunk: GitDiffHunk) -> String {
        let oldRange = lineRange(start: hunk.oldStart, count: hunk.oldCount)
        let newRange = lineRange(start: hunk.newStart, count: hunk.newCount)
        return "−\(oldRange)  +\(newRange)"
    }

    private static func lineRange(start: Int, count: Int) -> String {
        guard count > 1 else {
            return "\(start)"
        }
        return "\(start)–\(start + count - 1)"
    }

    private func appendContextLines(
        _ lines: [GitDiffLine],
        language: GitSyntaxLanguage,
        file: DiffStackFile,
        hunkID: String,
        layout: DiffLayoutMode,
        into rows: inout [DiffStackRow]
    ) {
        switch layout {
        case .unified:
            for line in lines {
                rows.append(
                    .line(
                        line,
                        language,
                        fileID: file.id,
                        hunkID: hunkID,
                        mutationMode: file.mutationMode
                    )
                )
            }
        case .sideBySide:
            for pair in SideBySideDiffBuilder.pairs(lines) {
                rows.append(
                    .sideBySide(
                        pair,
                        language,
                        fileID: file.id,
                        hunkID: hunkID,
                        mutationMode: file.mutationMode
                    )
                )
            }
        }
    }

    private static func estimatedRowCount(for groups: [DiffStackGroup]) -> Int {
        groups.reduce(0) { total, group in
            total + 1 + group.files.reduce(0) { fileTotal, file in
                guard file.isExpanded, let diff = file.diff else {
                    return fileTotal + 1
                }
                if file.imageDiff != nil {
                    return fileTotal + 2
                }
                return fileTotal + 1
                    + ((file.canToggleWholeFile || file.isLoadingWholeFile) ? 1 : 0)
                    + file.contextGaps.count(where: { $0.hiddenLineCount > 0 })
                    + file.contextGaps.reduce(0) { $0 + $1.revealedLines.count }
                    + diff.hunks.reduce(diff.hunks.count) { count, hunk in
                        count + hunk.lines.count
                    }
            }
        }
    }

    private static func maximumCodeColumnCountByHunkID(
        in rows: [DiffStackRow]
    ) -> [String: Int] {
        rows.reduce(into: [:]) { maximumByHunkID, row in
            switch row {
            case let .line(line, _, _, hunkID, _):
                maximumByHunkID[hunkID] = max(
                    maximumByHunkID[hunkID] ?? 0,
                    displayedColumnCount(line.content)
                )
            case let .sideBySide(pair, _, _, hunkID, _):
                maximumByHunkID[hunkID] = max(
                    maximumByHunkID[hunkID] ?? 0,
                    max(
                        displayedColumnCount(pair.old?.content ?? ""),
                        displayedColumnCount(pair.new?.content ?? "")
                    )
                )
            case .group, .file, .fileContextToggle, .hunk, .contextEdge, .image, .note:
                break
            }
        }
    }

    static func displayedColumnCount(_ content: String) -> Int {
        var columnCount = 0
        for character in content {
            if character == "\t" {
                columnCount += 4 - columnCount % 4
            } else if character.unicodeScalars.contains(where: {
                isWideCodePoint($0.value)
            }) {
                columnCount += 2
            } else {
                columnCount += 1
            }
            if columnCount >= Metrics.maximumDisplayedColumns {
                return Metrics.maximumDisplayedColumns + 2
            }
        }
        return columnCount + 2
    }

    private static func isWideCodePoint(_ value: UInt32) -> Bool {
        (0x1100...0x115F).contains(value)
            || (0x2329...0x232A).contains(value)
            || (0x2E80...0xA4CF).contains(value)
            || (0xAC00...0xD7A3).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0xFE10...0xFE19).contains(value)
            || (0xFE30...0xFE6F).contains(value)
            || (0xFF00...0xFF60).contains(value)
            || (0xFFE0...0xFFE6).contains(value)
            || (0x1F300...0x1FAFF).contains(value)
            || (0x20000...0x3FFFD).contains(value)
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

    private func handleWholeFileToggle(fileID: String) {
        guard let sectionIndex = fileSectionIndexByID[fileID] else {
            return
        }
        let file = fileSections[sectionIndex].file
        focusFile(fileID)
        pendingCodeAnchor = captureCodeAnchor(
            fileID: fileID,
            targetWholeFileState: !file.showsWholeFile
        )
        onToggleWholeFile?(fileID)
    }

    private func handleContextExpansion(fileID: String, gap: DiffStackContextGap) {
        focusFile(fileID)
        if let nextHunkAnchorID = gap.nextHunkAnchorID,
           let anchorRow = hunkRowIndexByAnchorID[nextHunkAnchorID] {
            tableView.layoutSubtreeIfNeeded()
            pendingHunkAnchor = PendingHunkAnchor(
                anchorID: nextHunkAnchorID,
                viewportY: tableView.rect(ofRow: anchorRow).minY - contentView.bounds.minY
            )
        }
        onExpandContext?(fileID, gap.id)
    }

    private func captureCodeAnchor(
        fileID: String,
        targetWholeFileState: Bool
    ) -> PendingCodeAnchor? {
        tableView.layoutSubtreeIfNeeded()
        let targetY = contentView.bounds.minY
            + (stickyClip.isHidden ? 0 : stickyClip.frame.height)
        let visibleRange = tableView.rows(in: contentView.bounds)
        let visibleIndexes = visibleRange.location == NSNotFound
            ? []
            : Array(visibleRange.location..<NSMaxRange(visibleRange))
        let visibleCandidates = visibleIndexes.compactMap { rowIndex -> (Int, GitDiffLine)? in
            guard let line = representativeLine(in: rows[rowIndex], fileID: fileID) else {
                return nil
            }
            return (rowIndex, line)
        }
        let visibleCandidate = visibleCandidates.min { lhs, rhs in
            abs(tableView.rect(ofRow: lhs.0).minY - targetY)
                < abs(tableView.rect(ofRow: rhs.0).minY - targetY)
        }
        let fallbackCandidate = fileSectionIndexByID[fileID].flatMap { sectionIndex in
            let section = fileSections[sectionIndex]
            return (section.headerRow..<section.endRow).lazy.compactMap {
                rowIndex -> (Int, GitDiffLine)? in
                guard let line = self.representativeLine(
                    in: self.rows[rowIndex],
                    fileID: fileID
                ) else {
                    return nil
                }
                return (rowIndex, line)
            }.first
        }
        let candidate = visibleCandidate ?? fallbackCandidate
        guard let candidate else {
            return nil
        }
        return PendingCodeAnchor(
            fileID: fileID,
            oldLineNumber: candidate.1.oldLineNumber,
            newLineNumber: candidate.1.newLineNumber,
            viewportY: tableView.rect(ofRow: candidate.0).minY - contentView.bounds.minY,
            targetWholeFileState: targetWholeFileState
        )
    }

    private func restorePendingCodeAnchor(groups: [DiffStackGroup]) {
        guard let anchor = pendingCodeAnchor,
              let file = groups.lazy.flatMap({ $0.files }).first(where: {
                  $0.id == anchor.fileID
              }),
              file.showsWholeFile == anchor.targetWholeFileState else {
            return
        }
        let candidates = rows.indices.compactMap { rowIndex -> (Int, GitDiffLine)? in
            guard let line = representativeLine(in: rows[rowIndex], fileID: anchor.fileID) else {
                return nil
            }
            return (rowIndex, line)
        }
        let exact = candidates.first { candidate in
            candidate.1.oldLineNumber == anchor.oldLineNumber
                && candidate.1.newLineNumber == anchor.newLineNumber
        }
        let target = exact ?? candidates.min { lhs, rhs in
            lineDistance(lhs.1, from: anchor) < lineDistance(rhs.1, from: anchor)
        }
        guard let target else {
            pendingCodeAnchor = nil
            return
        }
        restoreViewport(row: target.0, viewportY: anchor.viewportY)
        pendingCodeAnchor = nil
    }

    private func restorePendingHunkAnchorIfPossible() {
        guard let anchor = pendingHunkAnchor,
              let row = hunkRowIndexByAnchorID[anchor.anchorID] else {
            return
        }
        restoreViewport(row: row, viewportY: anchor.viewportY)
        pendingHunkAnchor = nil
    }

    private func restoreViewport(row: Int, viewportY: CGFloat) {
        let desiredOffset = tableView.rect(ofRow: row).minY - viewportY
        let maxOffset = max(0, tableView.bounds.height - contentView.bounds.height)
        contentView.scroll(
            to: NSPoint(x: 0, y: min(max(0, desiredOffset), maxOffset))
        )
        reflectScrolledClipView(contentView)
        updateStickyHeader()
    }

    private func representativeLine(
        in row: DiffStackRow,
        fileID: String
    ) -> GitDiffLine? {
        switch row {
        case let .line(line, _, candidateFileID, _, _):
            guard candidateFileID == fileID,
                  line.oldLineNumber != nil || line.newLineNumber != nil else {
                return nil
            }
            return line
        case let .sideBySide(pair, _, candidateFileID, _, _):
            guard candidateFileID == fileID else {
                return nil
            }
            return [pair.new, pair.old].compactMap { $0 }.first {
                $0.oldLineNumber != nil || $0.newLineNumber != nil
            }
        case .group, .file, .fileContextToggle, .hunk, .contextEdge, .image, .note:
            return nil
        }
    }

    private func lineDistance(_ line: GitDiffLine, from anchor: PendingCodeAnchor) -> Int {
        if let anchorLine = anchor.newLineNumber ?? anchor.oldLineNumber,
           let lineNumber = line.newLineNumber ?? line.oldLineNumber {
            return abs(lineNumber - anchorLine)
        }
        return Int.max
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
        backgroundColor = AgentGitPalette.canvas
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
        tableView.backgroundColor = AgentGitPalette.canvas
        tableView.focusRingType = .default
        tableView.setAccessibilityLabel("Diff Review")
        tableView.setAccessibilityHelp(
            "Drag across code to select characters. Use Tab and Shift-Tab to navigate hunks."
        )
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
        tableView.cancelPendingActionHandler = { [weak self] in
            self?.cancelPendingDiscardConfirmations() ?? false
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
        stickyFileHeader.reviewHandler = { [weak self] fileID in
            self?.focusFile(fileID)
            self?.onToggleReviewed?(fileID)
        }
        stickyFileHeader.wholeFileHandler = { [weak self] fileID in
            self?.handleWholeFileToggle(fileID: fileID)
        }
        stickyFileHeader.actionHandler = { [weak self] fileID, action in
            self?.focusFile(fileID)
            self?.onFileAction?(fileID, action)
        }
        stickyFileHeader.menuHandler = { [weak self] fileID in
            self?.contextMenu(forFileID: fileID)
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

    private func cancelPendingDiscardConfirmations() -> Bool {
        var cancelled = stickyFileHeader.cancelDiscardConfirmation()
        let visibleRows = tableView.rows(in: tableView.visibleRect)
        guard visibleRows.location != NSNotFound else {
            return cancelled
        }
        for row in visibleRows.location..<NSMaxRange(visibleRows) {
            guard let cell = tableView.view(
                atColumn: 0,
                row: row,
                makeIfNecessary: false
            ) else {
                continue
            }
            if let fileCell = cell as? DiffFileCellView {
                cancelled = fileCell.cancelDiscardConfirmation() || cancelled
            } else if let hunkCell = cell as? DiffHunkCellView {
                cancelled = hunkCell.cancelDiscardConfirmation() || cancelled
            }
        }
        return cancelled
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
        stickyClip.update(
            groupHeight: groupVisibleHeight,
            fileHeight: fileVisibleHeight
        )
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
        focusFile(fileID)
        scroll(toFileID: fileID)
        onToggleFile?(fileID)
    }

    private func handleClick(onRow row: Int) -> Bool {
        guard rows.indices.contains(row) else {
            return false
        }
        switch rows[row] {
        case let .file(file):
            focusFile(file.id)
            onToggleFile?(file.id)
            return true
        case let .group(group, _):
            onToggleGroup?(group.id)
            return true
        case .hunk, .line, .sideBySide, .fileContextToggle, .contextEdge, .image, .note:
            focusFile(atRow: row)
            return false
        }
    }

    private func focusFile(_ fileID: String) {
        onFocusFile?(fileID)
    }

    @discardableResult
    func focusFile(atRow row: Int) -> Bool {
        guard let section = fileSection(containingRow: row) else {
            return false
        }
        focusFile(section.file.id)
        return true
    }

    private func fileSection(containingRow row: Int) -> FileSection? {
        var lowerBound = 0
        var upperBound = fileSections.count - 1
        while lowerBound <= upperBound {
            let index = (lowerBound + upperBound) / 2
            let section = fileSections[index]
            if row < section.headerRow {
                upperBound = index - 1
            } else if row >= section.endRow {
                lowerBound = index + 1
            } else {
                return section
            }
        }
        return nil
    }

    func contextMenu(clickedRow: Int, selectedRows: IndexSet) -> NSMenu {
        focusFile(atRow: clickedRow)
        let menu = NSMenu()
        if !copyText(for: selectedRows).isEmpty {
            let copyItem = NSMenuItem(
                title: "Copy Selected Lines",
                action: #selector(DiffCopyingTableView.copy(_:)),
                keyEquivalent: ""
            )
            copyItem.target = tableView
            menu.addItem(copyItem)
        }

        guard rows.indices.contains(clickedRow) else {
            return menu
        }

        switch rows[clickedRow] {
        case let .file(file):
            addMenuItem(
                "Open File",
                command: .fileUtility(file.id, .openFile),
                to: menu,
                isEnabled: file.canOpenWorkingFile
            )
            addMenuItem(
                "Open with Visual Studio Code",
                command: .fileUtility(file.id, .openInVisualStudioCode),
                to: menu,
                isEnabled: file.canOpenWorkingFile && file.canOpenInVisualStudioCode
            )
            addMenuItem(
                "Reveal in Finder",
                command: .fileUtility(file.id, .revealInFinder),
                to: menu
            )
            let copyPathMenu = NSMenu(title: "Copy Path")
            addMenuItem(
                "Relative Path",
                command: .fileUtility(file.id, .copyRelativePath),
                to: copyPathMenu
            )
            addMenuItem(
                "Absolute Path",
                command: .fileUtility(file.id, .copyAbsolutePath),
                to: copyPathMenu
            )
            let copyPathItem = NSMenuItem(title: "Copy Path", action: nil, keyEquivalent: "")
            copyPathItem.submenu = copyPathMenu
            menu.addItem(copyPathItem)
            if file.diff != nil {
                menu.addItem(.separator())
                if file.canToggleWholeFile {
                    addMenuItem(
                        file.showsWholeFile ? "Show Changed Hunks" : "Show Whole File",
                        command: .wholeFile(file.id),
                        to: menu,
                        isEnabled: !file.isLoadingWholeFile
                    )
                }
                addMenuItem(
                    file.isReviewed ? "Mark as Unreviewed" : "Mark as Reviewed",
                    command: .review(file.id),
                    to: menu
                )
            }
            guard let mode = file.mutationMode else {
                return menu
            }
            if file.canApplyPrimaryAction || (mode == .working && file.canDiscard) {
                menu.addItem(.separator())
            }
            if file.canApplyPrimaryAction {
                addMenuItem(
                    mode.fileActionTitle,
                    command: .file(file.id, mode.primaryAction),
                    to: menu,
                    isEnabled: file.isMutationEnabled
                )
            }
            if mode == .working, file.canDiscard {
                addDiscardConfirmationMenuItem(
                    "Discard File",
                    command: .file(file.id, .discard),
                    to: menu,
                    isEnabled: file.isMutationEnabled
                )
            }

        case let .hunk(hunk):
            guard let mutationMode = hunk.mutationMode, !hunk.lineIDs.isEmpty else {
                return menu
            }
            menu.addItem(.separator())
            addMenuItem(
                mutationMode.hunkActionTitle,
                command: .selection(
                    hunk.fileID,
                    hunk.lineIDs,
                    mutationMode.primaryAction
                ),
                to: menu,
                isEnabled: hunk.isMutationEnabled
            )
            if mutationMode == .working {
                addDiscardConfirmationMenuItem(
                    "Discard Hunk",
                    command: .selection(hunk.fileID, hunk.lineIDs, .discard),
                    to: menu,
                    isEnabled: hunk.isMutationEnabled
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
                    to: menu,
                    isEnabled: mutationActionsEnabled
                )
                addDiscardConfirmationMenuItem(
                    "Discard Selected \(noun)",
                    command: .selection(selection.fileID, selection.lineIDs, .discard),
                    to: menu,
                    isEnabled: mutationActionsEnabled
                )
            case .staged:
                addMenuItem(
                    "Unstage Selected \(noun)",
                    command: .selection(selection.fileID, selection.lineIDs, .unstage),
                    to: menu,
                    isEnabled: mutationActionsEnabled
                )
            }

        case .group, .fileContextToggle, .contextEdge, .image, .note:
            break
        }
        return menu
    }

    private func contextMenu(forFileID fileID: String) -> NSMenu? {
        guard let row = fileRowIndexByID[fileID] else {
            return nil
        }
        return contextMenu(clickedRow: row, selectedRows: [])
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
            case let .line(line, _, candidateFileID, _, candidateMode):
                rowFileID = candidateFileID
                rowMode = candidateMode
                rowLineIDs = line.kind == .addition || line.kind == .deletion ? [line.id] : []
            case let .sideBySide(pair, _, candidateFileID, _, candidateMode):
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
            case .group, .file, .fileContextToggle, .hunk, .contextEdge, .image, .note:
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
        to menu: NSMenu,
        isEnabled: Bool = true
    ) {
        let item = NSMenuItem(
            title: title,
            action: #selector(runMenuMutation(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = DiffMutationMenuCommand(command)
        item.isEnabled = isEnabled
        menu.addItem(item)
    }

    private func addDiscardConfirmationMenuItem(
        _ title: String,
        command: DiffMutationMenuCommand.Value,
        to menu: NSMenu,
        isEnabled: Bool = true
    ) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let confirmationMenu = NSMenu(title: title)
        addMenuItem(
            "Confirm \(title) — Save Backup in Trash",
            command: command,
            to: confirmationMenu
        )
        item.submenu = confirmationMenu
        item.isEnabled = isEnabled
        menu.addItem(item)
    }

    @objc private func runMenuMutation(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? DiffMutationMenuCommand else {
            return
        }
        switch command.value {
        case let .wholeFile(fileID):
            onToggleWholeFile?(fileID)
        case let .review(fileID):
            onToggleReviewed?(fileID)
        case let .file(fileID, action):
            onFileAction?(fileID, action)
        case let .selection(fileID, lineIDs, action):
            onSelectionAction?(fileID, lineIDs, action)
        case let .fileUtility(fileID, action):
            onFileUtilityAction?(fileID, action)
        }
    }

    private func updateColumnWidth(force: Bool = false) {
        let viewportWidth = contentView.bounds.width
        guard force || appliedViewportWidth != viewportWidth else {
            return
        }
        appliedViewportWidth = viewportWidth
        // table 总宽等于 viewport；列宽由 AppKit 从总宽中扣除 inset style 的左右 padding。
        if tableView.frame.width != viewportWidth {
            tableView.setFrameSize(
                NSSize(width: viewportWidth, height: tableView.frame.height)
            )
        }
        tableView.sizeLastColumnToFit()
        for hunkID in Array(codeHorizontalOffsetByHunkID.keys) {
            guard codeContentWidthByHunkID[hunkID] != nil else {
                continue
            }
            let offset = codeHorizontalOffsetByHunkID[hunkID] ?? 0
            codeHorizontalOffsetByHunkID[hunkID] = min(
                offset,
                maximumCodeHorizontalOffset(for: hunkID)
            )
        }
        updateVisibleCodeViewports()
    }

    private func codeContentWidth(for hunkID: String) -> CGFloat {
        codeContentWidthByHunkID[hunkID] ?? 0
    }

    private var codeViewportWidth: CGFloat {
        switch layoutMode {
        case .unified:
            return max(
                0,
                tableColumn.width
                    - Metrics.unifiedCodeLeading
                    - Metrics.unifiedCodeTrailing
            )
        case .sideBySide:
            return max(
                0,
                tableColumn.width / 2
                    - Metrics.sideCodeLeading
                    - Metrics.sideCodeTrailing
            )
        }
    }

    private func maximumCodeHorizontalOffset(for hunkID: String) -> CGFloat {
        max(0, codeContentWidth(for: hunkID) - codeViewportWidth)
    }

    @discardableResult
    func scrollCodeHorizontally(by delta: CGFloat, atTablePoint tablePoint: NSPoint) -> Bool {
        guard let hunkID = codeHunkID(atTablePoint: tablePoint) else {
            return false
        }
        let currentOffset = codeHorizontalOffsetByHunkID[hunkID] ?? 0
        let proposedOffset = currentOffset - delta
        let clampedOffset = min(
            max(0, proposedOffset),
            maximumCodeHorizontalOffset(for: hunkID)
        )
        guard clampedOffset != currentOffset else {
            return true
        }
        codeHorizontalOffsetByHunkID[hunkID] = clampedOffset
        updateVisibleCodeViewports(for: hunkID)
        return true
    }

    private func codeHunkID(atTablePoint tablePoint: NSPoint) -> String? {
        let row = tableView.row(at: tablePoint)
        guard rows.indices.contains(row),
              let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) else {
            return nil
        }
        let cellPoint = cell.convert(tablePoint, from: tableView)
        switch rows[row] {
        case let .line(_, _, _, hunkID, _):
            return cellPoint.x >= Metrics.unifiedCodeLeading ? hunkID : nil
        case let .sideBySide(_, _, _, hunkID, _):
            let paneWidth = cell.bounds.width / 2
            guard paneWidth > 0 else {
                return nil
            }
            let paneX = cellPoint.x.truncatingRemainder(dividingBy: paneWidth)
            return paneX >= Metrics.sideCodeLeading ? hunkID : nil
        case .group, .file, .fileContextToggle, .hunk, .contextEdge, .image, .note:
            return nil
        }
    }

    private func updateVisibleCodeViewports(for targetHunkID: String? = nil) {
        let visibleRows = tableView.rows(in: contentView.bounds)
        guard visibleRows.location != NSNotFound else {
            return
        }
        for row in visibleRows.location..<NSMaxRange(visibleRows) {
            guard rows.indices.contains(row) else {
                continue
            }
            let hunkID: String
            switch rows[row] {
            case let .line(_, _, _, candidateHunkID, _),
                 let .sideBySide(_, _, _, candidateHunkID, _):
                hunkID = candidateHunkID
            case .group, .file, .fileContextToggle, .hunk, .contextEdge, .image, .note:
                continue
            }
            if let targetHunkID, hunkID != targetHunkID {
                continue
            }
            guard let cell = tableView.view(
                atColumn: 0,
                row: row,
                makeIfNecessary: false
            ) as? DiffCodeViewport else {
                continue
            }
            cell.updateCodeViewport(
                horizontalOffset: codeHorizontalOffsetByHunkID[hunkID] ?? 0,
                contentWidth: codeContentWidth(for: hunkID)
            )
        }
    }

    private func updateVisibleImagePreviews() {
        let visibleRows = tableView.rows(in: contentView.bounds)
        guard visibleRows.location != NSNotFound else {
            return
        }
        for row in visibleRows.location..<NSMaxRange(visibleRows) {
            guard rows.indices.contains(row),
                  case .image = rows[row],
                  let cell = tableView.view(
                      atColumn: 0,
                      row: row,
                      makeIfNecessary: false
                  ) as? DiffImageCellView else {
                continue
            }
            cell.setApplicationActive(isApplicationActive)
        }
    }

    private func copyText(for selectedRows: IndexSet) -> String {
        selectedRows.compactMap { rowIndex in
            guard rows.indices.contains(rowIndex) else {
                return nil
            }
            switch rows[rowIndex] {
            case let .hunk(hunk):
                return hunk.rawHeader
            case let .line(line, _, _, _, _):
                return line.copyText
            case let .sideBySide(pair, _, _, _, _):
                let values = [pair.old?.copyText, pair.new?.copyText].compactMap { $0 }
                if values.count == 2, values[0] == values[1] {
                    return values[0]
                }
                return values.joined(separator: "\n")
            case .file, .group, .fileContextToggle, .contextEdge, .image, .note:
                return nil
            }
        }.joined(separator: "\n")
    }
}

/// 只比较结构与预计算内容身份，避免每次 SwiftUI 更新都深比较上万行。
private struct DiffStackToken: Equatable {
    private struct EmptyGroupEntry: Equatable {
        let id: String
        let title: String?
        let emptyMessage: String
        let isExpanded: Bool
    }

    private struct ContextGapEntry: Equatable {
        let id: String
        let hiddenLineCount: Int
        let revealedLineCount: Int
        let contextRenderID: UInt64?
    }

    private struct Entry: Equatable {
        let id: String
        let groupID: String
        let groupTitle: String?
        let groupIsExpanded: Bool
        let statusLabel: String
        let path: String
        let originalPath: String?
        let isExpanded: Bool
        let showsWholeFile: Bool
        let isLoadingWholeFile: Bool
        let canToggleWholeFile: Bool
        let canOpenWorkingFile: Bool
        let canOpenInVisualStudioCode: Bool
        let canApplyPrimaryAction: Bool
        let canDiscard: Bool
        let isMutationEnabled: Bool
        let mutationSnapshotID: UInt64?
        let contextGaps: [ContextGapEntry]
        let mutationMode: DiffStackMutationMode?
        let diffRenderID: UInt64?
        let oldImageHash: Int?
        let newImageHash: Int?
    }

    private let entries: [Entry]
    private let emptyGroups: [EmptyGroupEntry]
    private let layout: DiffLayoutMode

    init(groups: [DiffStackGroup], layout: DiffLayoutMode) {
        var entries: [Entry] = []
        var emptyGroups: [EmptyGroupEntry] = []
        for group in groups {
            if group.files.isEmpty {
                emptyGroups.append(
                    EmptyGroupEntry(
                        id: group.id,
                        title: group.title,
                        emptyMessage: group.emptyMessage,
                        isExpanded: group.isExpanded
                    )
                )
            }
            for file in group.files {
                entries.append(
                    Entry(
                        id: file.id,
                        groupID: group.id,
                        groupTitle: group.title,
                        groupIsExpanded: group.isExpanded,
                        statusLabel: file.statusLabel,
                        path: file.path,
                        originalPath: file.originalPath,
                        isExpanded: file.isExpanded,
                        showsWholeFile: file.showsWholeFile,
                        isLoadingWholeFile: file.isLoadingWholeFile,
                        canToggleWholeFile: file.canToggleWholeFile,
                        canOpenWorkingFile: file.canOpenWorkingFile,
                        canOpenInVisualStudioCode: file.canOpenInVisualStudioCode,
                        canApplyPrimaryAction: file.canApplyPrimaryAction,
                        canDiscard: file.canDiscard,
                        isMutationEnabled: file.isMutationEnabled,
                        mutationSnapshotID: file.mutationSnapshotID?.rawValue,
                        contextGaps: file.contextGaps.map {
                            ContextGapEntry(
                                id: $0.id,
                                hiddenLineCount: $0.hiddenLineCount,
                                revealedLineCount: $0.revealedLines.count,
                                contextRenderID: $0.contextRenderID
                            )
                        },
                        mutationMode: file.mutationMode,
                        diffRenderID: file.diff?.renderID,
                        oldImageHash: file.imageDiff?.oldImage?.contentHash,
                        newImageHash: file.imageDiff?.newImage?.contentHash
                    )
                )
            }
        }
        self.entries = entries
        self.emptyGroups = emptyGroups
        self.layout = layout
    }
}

private struct DiffStackFilePresentationToken: Equatable {
    private struct Entry: Equatable {
        let id: String
        let isFocused: Bool
        let isReviewed: Bool
    }

    private let entries: [Entry]

    init(groups: [DiffStackGroup]) {
        entries = groups.flatMap(\.files).map {
            Entry(
                id: $0.id,
                isFocused: $0.isFocused,
                isReviewed: $0.isReviewed
            )
        }
    }

    func changedFileIDs(
        from previous: DiffStackFilePresentationToken
    ) -> Set<String> {
        let previousByID = Dictionary(
            uniqueKeysWithValues: previous.entries.map { ($0.id, $0) }
        )
        return Set(entries.compactMap { entry in
            previousByID[entry.id] == entry ? nil : entry.id
        })
    }
}

private struct DiffStackHunkRow {
    let anchorID: String
    let title: String
    let location: String
    let rawHeader: String
    let layout: DiffLayoutMode
    let fileID: String
    let lineIDs: Set<GitDiffLine.ID>
    let mutationMode: DiffStackMutationMode?
    let isMutationEnabled: Bool
    let mutationSnapshotID: DiffReviewSnapshotID?
    let showsWholeFile: Bool
    let isLoadingWholeFile: Bool
    let canToggleWholeFile: Bool
}

private enum DiffStackRow {
    case group(DiffStackGroup, count: Int)
    case file(DiffStackFile)
    case fileContextToggle(fileID: String, showsWholeFile: Bool, isLoading: Bool)
    case hunk(DiffStackHunkRow)
    case contextEdge(DiffStackContextGap, fileID: String)
    case line(
        GitDiffLine,
        GitSyntaxLanguage,
        fileID: String,
        hunkID: String,
        mutationMode: DiffStackMutationMode?
    )
    case sideBySide(
        GitDiffLinePair,
        GitSyntaxLanguage,
        fileID: String,
        hunkID: String,
        mutationMode: DiffStackMutationMode?
    )
    case image(GitImageDiff)
    case note(String)
}

@MainActor
func shouldToggleDiffRow(for hitView: NSView?) -> Bool {
    guard !(hitView is NSButton) else {
        return false
    }
    if let textField = hitView as? NSTextField, textField.isSelectable {
        return false
    }
    return true
}

private final class DiffCopyingTableView: NSTableView {
    var copyTextProvider: ((IndexSet) -> String)?
    var rowClickHandler: ((Int) -> Bool)?
    var dynamicMenuProvider: ((Int, IndexSet) -> NSMenu?)?
    var hunkNavigationHandler: ((Int) -> Bool)?
    var cancelPendingActionHandler: (() -> Bool)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hitView = hitTest(point)
        let clickedRow = row(at: point)
        if let textField = hitView as? NSTextField, textField.isSelectable {
            if clickedRow >= 0 {
                _ = rowClickHandler?(clickedRow)
            }
            window?.makeFirstResponder(textField)
            textField.mouseDown(with: event)
            return
        }
        if !shouldToggleDiffRow(for: hitView) {
            super.mouseDown(with: event)
            return
        }
        if clickedRow >= 0, rowClickHandler?(clickedRow) == true {
            return
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let shortcutModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 53,
           shortcutModifiers.isEmpty,
           cancelPendingActionHandler?() == true {
            return
        }
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

    override func cancelOperation(_ sender: Any?) {
        guard cancelPendingActionHandler?() != true else {
            return
        }
        super.cancelOperation(sender)
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
        case wholeFile(String)
        case review(String)
        case file(String, GitPendingSelectionAction)
        case selection(String, Set<GitDiffLine.ID>, GitPendingSelectionAction)
        case fileUtility(String, DiffStackFileUtilityAction)
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
    private var groupHeight: CGFloat = 0
    private var fileHeight: CGFloat = 0

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        AgentGitPalette.groupHeader.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: groupHeight).fill()
        AgentGitPalette.fileHeader.setFill()
        NSRect(x: 0, y: groupHeight, width: bounds.width, height: fileHeight).fill()
        if fileHeight > 0 {
            AgentGitPalette.separator.setFill()
            NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        }
    }

    func update(groupHeight: CGFloat, fileHeight: CGFloat) {
        guard self.groupHeight != groupHeight || self.fileHeight != fileHeight else {
            return
        }
        self.groupHeight = groupHeight
        self.fileHeight = fileHeight
        needsDisplay = true
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
        chevron.frame = NSRect(x: 10, y: 7, width: 14, height: 14)
        label.frame = NSRect(x: 26, y: 6, width: max(0, bounds.width - 40), height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        AgentGitPalette.groupHeader.setFill()
        dirtyRect.fill()
        AgentGitPalette.separator.withAlphaComponent(0.55).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        super.draw(dirtyRect)
    }

    func update(group: DiffStackGroup, count: Int) {
        groupID = group.id
        chevron.image = disclosureImage(isExpanded: group.isExpanded)
        label.stringValue = "\((group.title ?? "").uppercased()) · \(count)"
        toolTip = group.isExpanded
            ? "Collapse all \(countedLabel(count, singular: "file"))"
            : "Expand all \(countedLabel(count, singular: "file"))"
        needsLayout = true
        needsDisplay = true
    }
}

private final class DiffFileCellView: NSTableCellView {
    private static let discardConfirmationDuration: TimeInterval = 3
    static let identifier = NSUserInterfaceItemIdentifier("diff-file")

    var clickHandler: ((String) -> Void)?
    var reviewHandler: ((String) -> Void)?
    var wholeFileHandler: ((String) -> Void)?
    var actionHandler: ((String, GitPendingSelectionAction) -> Void)?
    var menuHandler: ((String) -> NSMenu?)?

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
    private let menuButton = NSButton(title: "", target: nil, action: nil)
    private let wholeFileButton = NSButton(title: "", target: nil, action: nil)
    private let reviewButton = NSButton(title: "", target: nil, action: nil)
    private let primaryButton = NSButton(title: "", target: nil, action: nil)
    private let discardButton = NSButton(title: "Discard", target: nil, action: nil)
    private var isFocused = false
    private var isReviewed = false
    private var canReview = false
    private var canToggleWholeFile = false
    private var canApplyPrimaryAction = false
    private var canDiscard = false
    private var isConfirmingDiscard = false
    private var discardConfirmationTimer: Timer?
    private var discardConfirmationSnapshotID: DiffReviewSnapshotID?
    private var fileID = ""
    private var mutationMode: DiffStackMutationMode?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(chevron)
        addSubview(status)
        addSubview(title)
        addSubview(stats)
        addSubview(menuButton)
        addSubview(wholeFileButton)
        addSubview(reviewButton)
        addSubview(primaryButton)
        addSubview(discardButton)
        configureWholeFileButton()
        configureReviewButton()
        configureMenuButton()
        configure(primaryButton, action: #selector(runPrimaryAction))
        configure(discardButton, action: #selector(runDiscardAction))
        title.lineBreakMode = .byTruncatingMiddle
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            resetDiscardConfirmation()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func cancelOperation(_ sender: Any?) {
        guard !cancelDiscardConfirmation() else {
            return
        }
        super.cancelOperation(sender)
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
        let primaryWidth: CGFloat = canApplyPrimaryAction ? 62 : 0
        let discardWidth: CGFloat = canDiscard ? 62 : 0
        let actionSpacing: CGFloat = primaryWidth > 0 && discardWidth > 0 ? 4 : 0
        let actionsWidth = primaryWidth + discardWidth
            + (discardWidth > 0 ? actionSpacing : 0)
        let menuWidth: CGFloat = 24
        let menuSpacing: CGFloat = 4
        let reviewWidth: CGFloat = canReview ? 24 : 0
        let reviewSpacing: CGFloat = canReview ? 4 : 0
        let wholeFileWidth: CGFloat = canToggleWholeFile ? 24 : 0
        let wholeFileSpacing: CGFloat = canToggleWholeFile ? 4 : 0
        let menuX = bounds.width - menuWidth - 10
        let actionX = menuX - actionsWidth - (actionsWidth > 0 ? menuSpacing : 0)
        let reviewX = actionX - reviewWidth - reviewSpacing
        let wholeFileX = reviewX - wholeFileWidth - wholeFileSpacing
        let statsX = wholeFileX - statsWidth - 6
        chevron.frame = NSRect(x: 10, y: 9, width: 14, height: 14)
        status.frame = NSRect(x: 26, y: 9, width: 16, height: 15)
        title.frame = NSRect(
            x: 48,
            y: 8,
            width: max(0, statsX - 54),
            height: 17
        )
        stats.frame = NSRect(
            x: statsX,
            y: 9,
            width: statsWidth,
            height: 15
        )
        menuButton.frame = NSRect(x: menuX, y: 4, width: menuWidth, height: 24)
        wholeFileButton.frame = NSRect(
            x: wholeFileX,
            y: 4,
            width: wholeFileWidth,
            height: 24
        )
        reviewButton.frame = NSRect(x: reviewX, y: 4, width: reviewWidth, height: 24)
        primaryButton.frame = NSRect(x: actionX, y: 5, width: primaryWidth, height: 22)
        discardButton.frame = NSRect(
            x: actionX + primaryWidth + actionSpacing,
            y: 5,
            width: discardWidth,
            height: 22
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        (isFocused ? AgentGitPalette.fileHeaderFocused : AgentGitPalette.fileHeader).setFill()
        dirtyRect.fill()
        if isReviewed {
            AgentGitPalette.additionBackground.withAlphaComponent(0.32).setFill()
            dirtyRect.fill()
        }
        if isFocused {
            AgentGitPalette.sidebarSelectionBorder.setFill()
            NSRect(x: 0, y: 0, width: 2, height: bounds.height).fill()
        }
        AgentGitPalette.separator.withAlphaComponent(0.7).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        super.draw(dirtyRect)
    }

    func update(
        file: DiffStackFile,
        reviewHandler: ((String) -> Void)? = nil,
        wholeFileHandler: ((String) -> Void)? = nil,
        actionHandler: ((String, GitPendingSelectionAction) -> Void)? = nil,
        menuHandler: ((String) -> NSMenu?)? = nil
    ) {
        if fileID != file.id
            || discardConfirmationSnapshotID != file.mutationSnapshotID
            || file.mutationMode != .working {
            resetDiscardConfirmation()
        }
        fileID = file.id
        discardConfirmationSnapshotID = file.mutationSnapshotID
        isFocused = file.isFocused
        isReviewed = file.isReviewed
        canReview = file.diff != nil
        canToggleWholeFile = false
        canApplyPrimaryAction = file.mutationMode != nil && file.canApplyPrimaryAction
        canDiscard = file.mutationMode == .working && file.canDiscard
        mutationMode = file.mutationMode
        self.reviewHandler = reviewHandler ?? self.reviewHandler
        self.wholeFileHandler = wholeFileHandler ?? self.wholeFileHandler
        self.actionHandler = actionHandler ?? self.actionHandler
        self.menuHandler = menuHandler ?? self.menuHandler
        chevron.image = disclosureImage(isExpanded: file.isExpanded)
        status.stringValue = file.statusLabel
        status.textColor = Self.color(for: file.status)
        title.attributedStringValue = Self.titleText(
            path: file.path,
            originalPath: file.originalPath
        )
        stats.attributedStringValue = Self.statsText(for: file.diff)
        let wholeFileTitle: String
        let wholeFileSymbol: String
        if file.isLoadingWholeFile {
            wholeFileTitle = "Loading Whole File…"
            wholeFileSymbol = "ellipsis"
        } else if file.showsWholeFile {
            wholeFileTitle = "Show Changed Hunks"
            wholeFileSymbol = "rectangle.compress.vertical"
        } else {
            wholeFileTitle = "Show Whole File"
            wholeFileSymbol = "rectangle.dashed"
        }
        wholeFileButton.image = NSImage(
            systemSymbolName: wholeFileSymbol,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        )
        wholeFileButton.isHidden = true
        wholeFileButton.isEnabled = !file.isLoadingWholeFile
        wholeFileButton.contentTintColor = file.showsWholeFile
            ? .controlAccentColor
            : .tertiaryLabelColor
        wholeFileButton.toolTip = wholeFileTitle
        wholeFileButton.setAccessibilityLabel(wholeFileTitle)
        let reviewSymbol = file.isReviewed ? "checkmark.circle.fill" : "circle"
        reviewButton.image = NSImage(
            systemSymbolName: reviewSymbol,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        )
        reviewButton.contentTintColor = file.isReviewed ? .systemGreen : .tertiaryLabelColor
        reviewButton.isHidden = !canReview
        let reviewTitle = file.isReviewed ? "Mark as Unreviewed" : "Mark as Reviewed"
        reviewButton.toolTip = reviewTitle
        reviewButton.setAccessibilityLabel(reviewTitle)
        primaryButton.title = file.mutationMode?.fileActionTitle ?? ""
        primaryButton.isHidden = !canApplyPrimaryAction
        primaryButton.isEnabled = file.isMutationEnabled
        primaryButton.contentTintColor = file.isMutationEnabled
            ? .labelColor
            : .tertiaryLabelColor
        primaryButton.toolTip = file.status == .conflicted
            ? "Stage the file after resolving its conflict markers"
            : primaryButton.title
        discardButton.isHidden = !canDiscard
        discardButton.isEnabled = file.isMutationEnabled
        if !isConfirmingDiscard {
            discardButton.contentTintColor = file.isMutationEnabled
                ? .secondaryLabelColor
                : .tertiaryLabelColor
        }
        if !file.isMutationEnabled {
            resetDiscardConfirmation()
        }
        let pathToolTip = file.originalPath.map { "\($0) → \(file.path)" } ?? file.path
        toolTip = file.status == .conflicted
            ? "\(pathToolTip)\nResolve conflict markers in the working file, then Stage the file."
            : pathToolTip
        needsLayout = true
        needsDisplay = true
    }

    @discardableResult
    func requestDiscardAction() -> Bool {
        guard canDiscard,
              !discardButton.isHidden,
              discardButton.isEnabled else {
            return false
        }
        runDiscardAction()
        return true
    }

    private func configure(_ button: NSButton, action: Selector) {
        button.target = self
        button.action = action
        button.bezelStyle = .recessed
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .medium)
    }

    private func configureReviewButton() {
        reviewButton.identifier = NSUserInterfaceItemIdentifier("review-toggle")
        reviewButton.target = self
        reviewButton.action = #selector(toggleReviewed)
        reviewButton.bezelStyle = .inline
        reviewButton.imagePosition = .imageOnly
        reviewButton.imageScaling = .scaleNone
    }

    private func configureMenuButton() {
        menuButton.identifier = NSUserInterfaceItemIdentifier("file-actions-menu")
        menuButton.target = self
        menuButton.action = #selector(showFileActions)
        menuButton.bezelStyle = .inline
        menuButton.imagePosition = .imageOnly
        menuButton.imageScaling = .scaleNone
        menuButton.image = NSImage(
            systemSymbolName: "ellipsis",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        )
        menuButton.contentTintColor = .secondaryLabelColor
        menuButton.toolTip = "File Actions"
        menuButton.setAccessibilityLabel("File Actions")
    }

    private func configureWholeFileButton() {
        wholeFileButton.identifier = NSUserInterfaceItemIdentifier("whole-file-toggle")
        wholeFileButton.target = self
        wholeFileButton.action = #selector(toggleWholeFile)
        wholeFileButton.bezelStyle = .inline
        wholeFileButton.imagePosition = .imageOnly
        wholeFileButton.imageScaling = .scaleNone
    }

    @objc private func toggleWholeFile() {
        resetDiscardConfirmation()
        wholeFileHandler?(fileID)
    }

    @objc private func toggleReviewed() {
        resetDiscardConfirmation()
        reviewHandler?(fileID)
    }

    @objc private func showFileActions() {
        resetDiscardConfirmation()
        guard let menu = menuHandler?(fileID) else {
            return
        }
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: menuButton.bounds.maxY + 2),
            in: menuButton
        )
    }

    @objc private func runPrimaryAction() {
        guard let action = mutationMode?.primaryAction else {
            return
        }
        resetDiscardConfirmation()
        actionHandler?(fileID, action)
    }

    @objc private func runDiscardAction() {
        guard isConfirmingDiscard else {
            beginDiscardConfirmation()
            return
        }
        resetDiscardConfirmation()
        actionHandler?(fileID, .discard)
    }

    private func beginDiscardConfirmation() {
        resetDiscardConfirmation()
        isConfirmingDiscard = true
        discardButton.title = "Confirm"
        discardButton.contentTintColor = .systemRed
        discardButton.toolTip = "Confirm discard; a recovery copy will be saved in Trash"
        let timer = Timer(
            timeInterval: Self.discardConfirmationDuration,
            target: self,
            selector: #selector(expireDiscardConfirmation),
            userInfo: nil,
            repeats: false
        )
        discardConfirmationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func expireDiscardConfirmation() {
        resetDiscardConfirmation()
    }

    func cancelDiscardConfirmation() -> Bool {
        guard isConfirmingDiscard else {
            return false
        }
        resetDiscardConfirmation()
        return true
    }

    private func resetDiscardConfirmation() {
        discardConfirmationTimer?.invalidate()
        discardConfirmationTimer = nil
        isConfirmingDiscard = false
        discardButton.title = "Discard"
        discardButton.contentTintColor = .secondaryLabelColor
        discardButton.toolTip = "Discard file changes; saves a recovery copy in Trash"
    }

    private static func titleText(
        path: String,
        originalPath: String?
    ) -> NSAttributedString {
        let text = NSMutableAttributedString()
        if let originalPath, originalPath != path {
            appendPath(originalPath, to: text, isCurrent: false)
            text.append(
                NSAttributedString(
                    string: "  →  ",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                        .foregroundColor: NSColor.secondaryLabelColor
                    ]
                )
            )
        }
        appendPath(path, to: text, isCurrent: true)
        return text
    }

    private static func appendPath(
        _ path: String,
        to text: NSMutableAttributedString,
        isCurrent: Bool
    ) {
        let name = (path as NSString).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent
        if !parent.isEmpty {
            text.append(
                NSAttributedString(
                    string: parent + "/",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 11.5, weight: .regular),
                        .foregroundColor: NSColor.secondaryLabelColor
                    ]
                )
            )
        }
        text.append(
            NSAttributedString(
                string: name,
                attributes: [
                    .font: NSFont.systemFont(
                        ofSize: 11.5,
                        weight: isCurrent ? .medium : .regular
                    ),
                    .foregroundColor: isCurrent
                        ? NSColor.labelColor
                        : NSColor.secondaryLabelColor
                ]
            )
        )
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
                attributes: [
                    .font: font,
                    .foregroundColor: AgentGitPalette.additionText
                ]
            )
        )
        text.append(
            NSAttributedString(
                string: "  −\(diff.deletedLineCount)",
                attributes: [
                    .font: font,
                    .foregroundColor: AgentGitPalette.deletionText
                ]
            )
        )
        return text
    }

    private static func color(for status: DiffStackStatus) -> NSColor {
        switch status {
        case .added, .untracked: AgentGitPalette.statusAdded
        case .deleted: AgentGitPalette.statusDeleted
        case .renamed: AgentGitPalette.statusRenamed
        case .conflicted: AgentGitPalette.statusConflicted
        case .modified: AgentGitPalette.statusModified
        }
    }
}

private final class DiffImageCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("diff-image")

    private let beforePane = DiffImagePaneView(
        title: "Before",
        identifier: "diff-image-before"
    )
    private let afterPane = DiffImagePaneView(
        title: "After",
        identifier: "diff-image-after"
    )
    private let separator = DiffImageSeparatorView()
    private var renderedOldImageID: DiffImagePreviewID?
    private var renderedNewImageID: DiffImagePreviewID?
    private var hasRenderedImages = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(beforePane)
        addSubview(afterPane)
        addSubview(separator)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        let verticalPadding: CGFloat = 10
        let separatorWidth: CGFloat = 1
        let paneWidth = floor(max(0, bounds.width - 24 - separatorWidth) / 2)
        let contentWidth = paneWidth * 2 + separatorWidth
        let originX = floor((bounds.width - contentWidth) / 2)
        let paneHeight = max(0, bounds.height - verticalPadding * 2)
        beforePane.frame = NSRect(
            x: originX,
            y: verticalPadding,
            width: paneWidth,
            height: paneHeight
        )
        separator.frame = NSRect(
            x: beforePane.frame.maxX,
            y: verticalPadding + 1,
            width: separatorWidth,
            height: max(0, paneHeight - 2)
        )
        afterPane.frame = NSRect(
            x: separator.frame.maxX,
            y: verticalPadding,
            width: paneWidth,
            height: paneHeight
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        super.draw(dirtyRect)
    }

    func setApplicationActive(_ isActive: Bool) {
        beforePane.setApplicationActive(isActive)
        afterPane.setApplicationActive(isActive)
    }

    func update(imageDiff: GitImageDiff) {
        let oldImageID = imageDiff.oldImage.map(DiffImagePreviewID.init)
        let newImageID = imageDiff.newImage.map(DiffImagePreviewID.init)
        guard !hasRenderedImages
                || renderedOldImageID != oldImageID
                || renderedNewImageID != newImageID else {
            return
        }
        hasRenderedImages = true
        renderedOldImageID = oldImageID
        renderedNewImageID = newImageID
        beforePane.update(
            image: imageDiff.oldImage,
            emptyMessage: "No previous image"
        )
        afterPane.update(
            image: imageDiff.newImage,
            emptyMessage: "Image deleted"
        )
        needsLayout = true
        needsDisplay = true
    }
}

private final class DiffImageSeparatorView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        dirtyRect.fill()
    }
}

private final class DiffImagePaneView: NSView {
    private let titleLabel = DiffTextField(
        font: .systemFont(ofSize: 11, weight: .semibold),
        textColor: .secondaryLabelColor,
        alignment: .left,
        selectable: false
    )
    private let metadataLabel = DiffTextField(
        font: .systemFont(ofSize: 10, weight: .regular),
        textColor: .tertiaryLabelColor,
        alignment: .right,
        selectable: false
    )
    private let canvas = DiffImageCanvasView()
    private let placeholderLabel = DiffTextField(
        font: .systemFont(ofSize: 12, weight: .medium),
        textColor: .tertiaryLabelColor,
        alignment: .center,
        selectable: false
    )
    private var renderedBlobID: DiffImagePreviewID?
    private var hasRenderedContent = false
    private var previewTask: Task<Void, Never>?
    private var currentBlob: GitImageBlob?
    private var currentEmptyMessage = ""
    private var isApplicationActive = true
    private let paneTitle: String

    override var isFlipped: Bool { true }

    init(title: String, identifier: String) {
        paneTitle = title
        super.init(frame: .zero)
        self.identifier = NSUserInterfaceItemIdentifier(identifier)
        titleLabel.stringValue = title
        metadataLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(titleLabel)
        addSubview(metadataLabel)
        addSubview(canvas)
        addSubview(placeholderLabel)
        canvas.updateAccessibility(
            label: "\(title) image",
            value: "No image loaded"
        )
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        previewTask?.cancel()
    }

    override func layout() {
        super.layout()
        let horizontalPadding: CGFloat = 12
        let headerHeight: CGFloat = 38
        let titleWidth: CGFloat = 52
        titleLabel.frame = NSRect(
            x: horizontalPadding,
            y: 11,
            width: titleWidth,
            height: 16
        )
        metadataLabel.frame = NSRect(
            x: horizontalPadding + titleWidth + 8,
            y: 11,
            width: max(0, bounds.width - horizontalPadding * 2 - titleWidth - 8),
            height: 16
        )
        canvas.frame = NSRect(
            x: 10,
            y: headerHeight,
            width: max(0, bounds.width - 20),
            height: max(0, bounds.height - headerHeight - 10)
        )
        placeholderLabel.frame = NSRect(
            x: canvas.frame.minX + 12,
            y: canvas.frame.midY - 10,
            width: max(0, canvas.frame.width - 24),
            height: 20
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        NSColor.separatorColor.withAlphaComponent(0.7).setStroke()
        let border = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: 6,
            yRadius: 6
        )
        border.lineWidth = 1
        border.stroke()
        NSColor.separatorColor.withAlphaComponent(0.7).setFill()
        NSRect(x: 1, y: 37, width: max(0, bounds.width - 2), height: 1).fill()
        super.draw(dirtyRect)
    }

    func update(image blob: GitImageBlob?, emptyMessage: String) {
        currentBlob = blob
        currentEmptyMessage = emptyMessage
        let blobID = blob.map(DiffImagePreviewID.init)
        let contentChanged = !hasRenderedContent || renderedBlobID != blobID
        guard isApplicationActive else {
            if contentChanged {
                renderedBlobID = blobID
                hasRenderedContent = false
            }
            suspendPreviewIfNeeded(force: contentChanged)
            return
        }
        guard contentChanged else {
            return
        }
        hasRenderedContent = true
        renderedBlobID = blobID
        previewTask?.cancel()
        previewTask = nil

        guard let blob else {
            canvas.image = nil
            metadataLabel.stringValue = ""
            placeholderLabel.stringValue = emptyMessage
            placeholderLabel.isHidden = false
            toolTip = emptyMessage
            canvas.updateAccessibility(
                label: "\(paneTitle) image",
                value: emptyMessage
            )
            return
        }
        let byteText = ByteCountFormatter.string(
            fromByteCount: Int64(blob.contents.count),
            countStyle: .file
        )
        let previewID = DiffImagePreviewID(blob)
        metadataLabel.stringValue = "\(blob.path) · \(byteText)"
        toolTip = metadataLabel.stringValue
        if let preview = DiffImagePreviewCache.shared.preview(for: previewID) {
            apply(preview, path: blob.path, byteText: byteText)
            return
        }
        canvas.image = nil
        placeholderLabel.stringValue = "Loading preview…"
        placeholderLabel.isHidden = false
        canvas.updateAccessibility(
            label: "\(paneTitle) image",
            value: "Loading preview for \(blob.path)"
        )
        let contents = blob.contents
        previewTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                DiffImagePreviewDecoder.decode(contents)
            }
            let preview = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled,
                  let self,
                  self.renderedBlobID == previewID else {
                return
            }
            self.previewTask = nil
            guard let preview else {
                self.canvas.image = nil
                self.placeholderLabel.stringValue = "Unable to decode image"
                self.placeholderLabel.isHidden = false
                self.canvas.updateAccessibility(
                    label: "\(self.paneTitle) image",
                    value: "Unable to decode \(blob.path)"
                )
                self.needsDisplay = true
                return
            }
            DiffImagePreviewCache.shared.insert(preview, for: previewID)
            self.apply(preview, path: blob.path, byteText: byteText)
        }
    }

    func setApplicationActive(_ isActive: Bool) {
        guard isApplicationActive != isActive else {
            return
        }
        isApplicationActive = isActive
        if isActive {
            guard !hasRenderedContent else {
                return
            }
            update(image: currentBlob, emptyMessage: currentEmptyMessage)
        } else {
            suspendPreviewIfNeeded()
        }
    }

    private func suspendPreviewIfNeeded(force: Bool = false) {
        guard force || previewTask != nil || !hasRenderedContent else {
            return
        }
        previewTask?.cancel()
        previewTask = nil
        hasRenderedContent = false
        canvas.image = nil
        if currentBlob == nil {
            metadataLabel.stringValue = ""
            placeholderLabel.stringValue = currentEmptyMessage
            toolTip = currentEmptyMessage
            canvas.updateAccessibility(
                label: "\(paneTitle) image",
                value: currentEmptyMessage
            )
        } else {
            placeholderLabel.stringValue = "Preview paused in background"
            toolTip = placeholderLabel.stringValue
            canvas.updateAccessibility(
                label: "\(paneTitle) image",
                value: "Preview paused in background"
            )
        }
        placeholderLabel.isHidden = false
        needsDisplay = true
    }

    private func apply(
        _ preview: DiffImagePreview,
        path: String,
        byteText: String
    ) {
        canvas.image = NSImage(
            cgImage: preview.image,
            size: NSSize(
                width: CGFloat(preview.image.width),
                height: CGFloat(preview.image.height)
            )
        )
        metadataLabel.stringValue = [
            path,
            "\(preview.originalPixelWidth)×\(preview.originalPixelHeight)",
            byteText
        ].joined(separator: " · ")
        canvas.updateAccessibility(
            label: "\(paneTitle) image",
            value: metadataLabel.stringValue
        )
        placeholderLabel.isHidden = true
        toolTip = metadataLabel.stringValue
        needsDisplay = true
    }
}

private final class DiffImageCanvasView: NSView {
    private let imageView = NSImageView()

    var image: NSImage? {
        get { imageView.image }
        set { imageView.image = newValue }
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("diff-image-canvas")
        imageView.identifier = NSUserInterfaceItemIdentifier("diff-image-content")
        imageView.imageAlignment = .alignCenter
        imageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(imageView)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        imageView.frame = bounds.insetBy(dx: 12, dy: 12)
    }

    func updateAccessibility(label: String, value: String) {
        imageView.setAccessibilityLabel(label)
        imageView.setAccessibilityValue(value)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        let squareSize: CGFloat = 10
        let alternateColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08)
        alternateColor.setFill()
        var y: CGFloat = 0
        var row = 0
        while y < bounds.height {
            var x: CGFloat = row.isMultiple(of: 2) ? 0 : squareSize
            while x < bounds.width {
                NSRect(
                    x: x,
                    y: y,
                    width: min(squareSize, bounds.width - x),
                    height: min(squareSize, bounds.height - y)
                ).fill()
                x += squareSize * 2
            }
            y += squareSize
            row += 1
        }
        super.draw(dirtyRect)
    }
}

private final class DiffFileContextToggleCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("diff-file-context-toggle")

    private let button = NSButton(title: "", target: nil, action: nil)
    private var fileID = ""
    private var toggleHandler: ((String) -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        button.identifier = NSUserInterfaceItemIdentifier("whole-file-toggle")
        button.target = self
        button.action = #selector(toggleWholeFile)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.contentTintColor = .secondaryLabelColor
        addSubview(button)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        button.frame = NSRect(x: 7, y: 2, width: 24, height: 24)
    }

    override func draw(_ dirtyRect: NSRect) {
        AgentGitPalette.fileContext.setFill()
        dirtyRect.fill()
        AgentGitPalette.separator.withAlphaComponent(0.55).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        super.draw(dirtyRect)
    }

    func update(
        fileID: String,
        showsWholeFile: Bool,
        isLoading: Bool,
        toggleHandler: @escaping (String) -> Void
    ) {
        self.fileID = fileID
        self.toggleHandler = toggleHandler
        let title: String
        let symbol: String
        if isLoading {
            title = "Loading entire file…"
            symbol = "ellipsis"
        } else if showsWholeFile {
            title = "Show only modified hunks"
            symbol = "rectangle.compress.vertical"
        } else {
            title = "Show entire file"
            symbol = "rectangle.expand.vertical"
        }
        button.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        )
        button.isEnabled = !isLoading
        button.toolTip = title
        button.setAccessibilityLabel(title)
        needsLayout = true
        needsDisplay = true
    }

    @objc private func toggleWholeFile() {
        toggleHandler?(fileID)
    }
}

private final class DiffContextEdgeCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("diff-context-edge")

    private let button = NSButton(title: "", target: nil, action: nil)
    private var fileID = ""
    private var gap: DiffStackContextGap?
    private var expandHandler: ((String, DiffStackContextGap) -> Void)?
    private var isHovered = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        button.identifier = NSUserInterfaceItemIdentifier("hunk-context-expand")
        button.target = self
        button.action = #selector(expand)
        button.bezelStyle = .inline
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.contentTintColor = .secondaryLabelColor
        button.image = NSImage(
            systemSymbolName: "ellipsis",
            accessibilityDescription: "Expand hidden context"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
        )
        addSubview(button)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self
            )
        )
        updateHoverAppearance()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        button.frame = NSRect(x: 6, y: 0, width: 24, height: bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        AgentGitPalette.canvas.setFill()
        dirtyRect.fill()
        AgentGitPalette.separator.withAlphaComponent(0.65).setFill()
        NSRect(x: 34, y: bounds.midY, width: max(0, bounds.width - 34), height: 1).fill()
        super.draw(dirtyRect)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateHoverAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateHoverAppearance()
    }

    func update(
        gap: DiffStackContextGap,
        fileID: String,
        expandHandler: @escaping (String, DiffStackContextGap) -> Void
    ) {
        self.gap = gap
        self.fileID = fileID
        self.expandHandler = expandHandler
        let shownLineCount = min(20, gap.hiddenLineCount)
        let title = gap.hiddenLineCount == shownLineCount
            ? "Show \(shownLineCount) hidden lines"
            : "Show \(shownLineCount) of \(gap.hiddenLineCount) hidden lines"
        button.toolTip = title
        button.setAccessibilityLabel(title)
        needsLayout = true
        needsDisplay = true
    }

    @objc private func expand() {
        guard let gap else {
            return
        }
        expandHandler?(fileID, gap)
    }

    private func updateHoverAppearance() {
        button.alphaValue = isHovered ? 1 : 0.48
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
    private static let discardConfirmationDuration: TimeInterval = 3
    static let identifier = NSUserInterfaceItemIdentifier("diff-hunk")

    private let unifiedTitle = DiffTextField(
        font: .monospacedSystemFont(ofSize: 11, weight: .medium),
        textColor: .secondaryLabelColor,
        alignment: .left,
        selectable: false
    )
    private let oldTitle = DiffTextField(
        font: .monospacedSystemFont(ofSize: 11, weight: .medium),
        textColor: .secondaryLabelColor,
        alignment: .left,
        selectable: false
    )
    private let newTitle = DiffTextField(
        font: .monospacedSystemFont(ofSize: 11, weight: .medium),
        textColor: .secondaryLabelColor,
        alignment: .left,
        selectable: false
    )
    private let marker = DiffTextField(
        font: .monospacedSystemFont(ofSize: 10.5, weight: .medium),
        textColor: .tertiaryLabelColor,
        alignment: .center,
        selectable: false
    )
    private let location = DiffTextField(
        font: .monospacedSystemFont(ofSize: 10.5, weight: .medium),
        textColor: .tertiaryLabelColor,
        alignment: .right,
        selectable: false
    )
    private let paneDivider = NSBox()
    private let wholeFileButton = NSButton(title: "", target: nil, action: nil)
    private let primaryButton = NSButton(title: "", target: nil, action: nil)
    private let discardButton = NSButton(title: "Discard", target: nil, action: nil)
    private var fileID = ""
    private var lineIDs: Set<GitDiffLine.ID> = []
    private var mutationMode: DiffStackMutationMode?
    private var discardConfirmationID = ""
    private var isConfirmingDiscard = false
    private var discardConfirmationTimer: Timer?
    private var canToggleWholeFile = false
    private var showsWholeFile = false
    private var isLoadingWholeFile = false
    private var isHovered = false
    private var layoutMode: DiffLayoutMode = .unified
    private var wholeFileHandler: ((String) -> Void)?
    private var actionHandler: ((String, Set<GitDiffLine.ID>, GitPendingSelectionAction) -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        marker.stringValue = "@@"
        marker.identifier = NSUserInterfaceItemIdentifier("hunk-marker")
        marker.setAccessibilityElement(false)
        addSubview(marker)
        unifiedTitle.identifier = NSUserInterfaceItemIdentifier("hunk-title-unified")
        oldTitle.identifier = NSUserInterfaceItemIdentifier("hunk-title-old")
        newTitle.identifier = NSUserInterfaceItemIdentifier("hunk-title-new")
        addSubview(unifiedTitle)
        addSubview(oldTitle)
        addSubview(newTitle)
        location.identifier = NSUserInterfaceItemIdentifier("hunk-location")
        addSubview(location)
        paneDivider.boxType = .separator
        addSubview(paneDivider)
        addSubview(wholeFileButton)
        addSubview(primaryButton)
        addSubview(discardButton)
        wholeFileButton.identifier = NSUserInterfaceItemIdentifier("hunk-whole-file-toggle")
        wholeFileButton.target = self
        wholeFileButton.action = #selector(toggleWholeFile)
        wholeFileButton.bezelStyle = .inline
        wholeFileButton.imagePosition = .imageOnly
        wholeFileButton.imageScaling = .scaleNone
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self
            )
        )
        configure(primaryButton, action: #selector(runPrimaryAction))
        configure(discardButton, action: #selector(runDiscardAction))
        unifiedTitle.lineBreakMode = .byTruncatingTail
        oldTitle.lineBreakMode = .byTruncatingTail
        newTitle.lineBreakMode = .byTruncatingTail
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            resetDiscardConfirmation()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func cancelOperation(_ sender: Any?) {
        guard !cancelDiscardConfirmation() else {
            return
        }
        super.cancelOperation(sender)
    }

    override func layout() {
        super.layout()
        let primaryWidth: CGFloat = mutationMode == nil ? 0 : 86
        let discardWidth: CGFloat = mutationMode == .working ? 62 : 0
        let spacing: CGFloat = discardWidth > 0 ? 4 : 0
        let actionsWidth = primaryWidth + discardWidth + spacing
        wholeFileButton.frame = NSRect(x: 7, y: 1, width: 22, height: 22)
        marker.frame = NSRect(x: 8, y: 4, width: 22, height: 16)
        let labelX: CGFloat = 38
        let actionX = bounds.width - actionsWidth - 12
        let showsLocation = bounds.width >= (layoutMode == .sideBySide ? 820 : 500)
        let locationWidth: CGFloat = showsLocation ? 94 : 0
        let locationX = max(labelX, actionX - locationWidth - 8)
        location.isHidden = !showsLocation
        location.frame = NSRect(
            x: locationX,
            y: 4,
            width: max(0, actionX - locationX - 8),
            height: 16
        )
        primaryButton.frame = NSRect(x: actionX, y: 1, width: primaryWidth, height: 22)
        discardButton.frame = NSRect(
            x: actionX + primaryWidth + spacing,
            y: 1,
            width: discardWidth,
            height: 22
        )
        let titleHeight = max(0, bounds.height - 8)
        switch layoutMode {
        case .unified:
            unifiedTitle.frame = NSRect(
                x: labelX,
                y: 3,
                width: max(0, locationX - labelX - 8),
                height: titleHeight
            )
            oldTitle.frame = .zero
            newTitle.frame = .zero
            paneDivider.frame = .zero
        case .sideBySide:
            let paneWidth = bounds.width / 2
            unifiedTitle.frame = .zero
            oldTitle.frame = NSRect(
                x: labelX,
                y: 3,
                width: max(0, paneWidth - labelX - 8),
                height: titleHeight
            )
            let newTitleX = paneWidth + labelX
            newTitle.frame = NSRect(
                x: newTitleX,
                y: 3,
                width: max(0, locationX - newTitleX - 8),
                height: titleHeight
            )
            paneDivider.frame = NSRect(
                x: paneWidth - 0.5,
                y: 0,
                width: 1,
                height: bounds.height
            )
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        AgentGitPalette.hunkHeader.setFill()
        dirtyRect.fill()
        AgentGitPalette.separator.withAlphaComponent(0.55).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        super.draw(dirtyRect)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateWholeFileButtonVisibility()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateWholeFileButtonVisibility()
    }

    func update(
        hunk: DiffStackHunkRow,
        wholeFileHandler: ((String) -> Void)?,
        actionHandler: ((String, Set<GitDiffLine.ID>, GitPendingSelectionAction) -> Void)?
    ) {
        if fileID != hunk.fileID {
            isHovered = false
        }
        let confirmationID = "\(hunk.fileID):"
            + "\(hunk.mutationSnapshotID?.rawValue ?? 0):"
            + "\(hunk.lineIDs.sorted())"
        if discardConfirmationID != confirmationID || hunk.mutationMode != .working {
            resetDiscardConfirmation()
        }
        discardConfirmationID = confirmationID
        unifiedTitle.stringValue = hunk.title
        oldTitle.stringValue = hunk.title
        newTitle.stringValue = hunk.title
        location.stringValue = hunk.location
        unifiedTitle.toolTip = hunk.rawHeader
        oldTitle.toolTip = hunk.rawHeader
        newTitle.toolTip = hunk.rawHeader
        layoutMode = hunk.layout
        unifiedTitle.isHidden = hunk.layout != .unified
        oldTitle.isHidden = hunk.layout != .sideBySide
        newTitle.isHidden = hunk.layout != .sideBySide
        paneDivider.isHidden = hunk.layout != .sideBySide
        fileID = hunk.fileID
        lineIDs = hunk.lineIDs
        mutationMode = hunk.mutationMode
        canToggleWholeFile = false
        showsWholeFile = hunk.showsWholeFile
        isLoadingWholeFile = hunk.isLoadingWholeFile
        self.wholeFileHandler = wholeFileHandler
        self.actionHandler = actionHandler
        primaryButton.title = hunk.mutationMode?.hunkActionTitle ?? ""
        primaryButton.isHidden = hunk.mutationMode == nil || hunk.lineIDs.isEmpty
        primaryButton.isEnabled = hunk.isMutationEnabled
        primaryButton.contentTintColor = hunk.isMutationEnabled
            ? .labelColor
            : .tertiaryLabelColor
        discardButton.isHidden = hunk.mutationMode != .working || hunk.lineIDs.isEmpty
        discardButton.isEnabled = hunk.isMutationEnabled
        if !isConfirmingDiscard {
            discardButton.contentTintColor = hunk.isMutationEnabled
                ? .secondaryLabelColor
                : .tertiaryLabelColor
        }
        if !hunk.isMutationEnabled {
            resetDiscardConfirmation()
        }
        let wholeFileTitle: String
        let wholeFileSymbol: String
        if hunk.isLoadingWholeFile {
            wholeFileTitle = "Loading Whole File…"
            wholeFileSymbol = "ellipsis"
        } else if hunk.showsWholeFile {
            wholeFileTitle = "Show Changed Hunks"
            wholeFileSymbol = "rectangle.compress.vertical"
        } else {
            wholeFileTitle = "Show Whole File"
            wholeFileSymbol = "rectangle.dashed"
        }
        wholeFileButton.image = NSImage(
            systemSymbolName: wholeFileSymbol,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        )
        wholeFileButton.isEnabled = !hunk.isLoadingWholeFile
        wholeFileButton.contentTintColor = hunk.showsWholeFile
            ? .controlAccentColor
            : .secondaryLabelColor
        wholeFileButton.toolTip = wholeFileTitle
        wholeFileButton.setAccessibilityLabel(wholeFileTitle)
        updateWholeFileButtonVisibility()
        toolTip = "\(hunk.rawHeader)\nTab: Next Hunk  ·  Shift-Tab: Previous Hunk"
        needsLayout = true
        needsDisplay = true
    }

    private func configure(_ button: NSButton, action: Selector) {
        button.target = self
        button.action = action
        button.bezelStyle = .recessed
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .medium)
    }

    @objc private func runPrimaryAction() {
        guard let action = mutationMode?.primaryAction else {
            return
        }
        resetDiscardConfirmation()
        actionHandler?(fileID, lineIDs, action)
    }

    @objc private func toggleWholeFile() {
        resetDiscardConfirmation()
        wholeFileHandler?(fileID)
    }

    @objc private func runDiscardAction() {
        guard isConfirmingDiscard else {
            beginDiscardConfirmation()
            return
        }
        resetDiscardConfirmation()
        actionHandler?(fileID, lineIDs, .discard)
    }

    private func beginDiscardConfirmation() {
        resetDiscardConfirmation()
        isConfirmingDiscard = true
        discardButton.title = "Confirm"
        discardButton.contentTintColor = .systemRed
        discardButton.toolTip = "Confirm discard hunk; a recovery copy will be saved in Trash"
        let timer = Timer(
            timeInterval: Self.discardConfirmationDuration,
            target: self,
            selector: #selector(expireDiscardConfirmation),
            userInfo: nil,
            repeats: false
        )
        discardConfirmationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func expireDiscardConfirmation() {
        resetDiscardConfirmation()
    }

    func cancelDiscardConfirmation() -> Bool {
        guard isConfirmingDiscard else {
            return false
        }
        resetDiscardConfirmation()
        return true
    }

    private func resetDiscardConfirmation() {
        discardConfirmationTimer?.invalidate()
        discardConfirmationTimer = nil
        isConfirmingDiscard = false
        discardButton.title = "Discard"
        discardButton.contentTintColor = .secondaryLabelColor
        discardButton.toolTip = "Discard hunk changes; saves a recovery copy in Trash"
    }

    private func updateWholeFileButtonVisibility() {
        let showsWholeFileButton = canToggleWholeFile
            && (isHovered || showsWholeFile || isLoadingWholeFile)
        wholeFileButton.isHidden = !showsWholeFileButton
        marker.isHidden = showsWholeFileButton
    }
}

@MainActor
private protocol DiffCodeViewport: AnyObject {
    func updateCodeViewport(horizontalOffset: CGFloat, contentWidth: CGFloat)
}

private final class DiffLineCellView: NSTableCellView, DiffCodeViewport {
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
        selectable: true
    )
    private let contentClip = NSView()
    private var kind: GitDiffLineKind = .context
    private var horizontalOffset: CGFloat = 0
    private var codeContentWidth: CGFloat = 0
    private var renderedLine: GitDiffLine?
    private var renderedLanguage: GitSyntaxLanguage?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(oldLineNumber)
        addSubview(newLineNumber)
        addSubview(marker)
        contentClip.identifier = NSUserInterfaceItemIdentifier("diff-unified-code-clip")
        contentClip.wantsLayer = true
        contentClip.layer?.masksToBounds = true
        content.identifier = NSUserInterfaceItemIdentifier("diff-unified-code-content")
        contentClip.addSubview(content)
        addSubview(contentClip)
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
        contentClip.frame = NSRect(
            x: lineNumberWidth * 2 + 22,
            y: 0,
            width: max(0, bounds.width - lineNumberWidth * 2 - 34),
            height: bounds.height
        )
        content.frame = NSRect(
            x: -horizontalOffset,
            y: 0,
            width: max(contentClip.bounds.width, codeContentWidth),
            height: contentClip.bounds.height
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        backgroundColor.setFill()
        dirtyRect.fill()
        AgentGitPalette.codeGutter.setFill()
        NSRect(x: 0, y: dirtyRect.minY, width: 112, height: dirtyRect.height).fill()
        super.draw(dirtyRect)
    }

    func update(line: GitDiffLine, language: GitSyntaxLanguage) {
        guard renderedLine != line || renderedLanguage != language else {
            return
        }
        renderedLine = line
        renderedLanguage = language
        kind = line.kind
        oldLineNumber.stringValue = line.oldLineNumber.map(String.init) ?? ""
        newLineNumber.stringValue = line.newLineNumber.map(String.init) ?? ""
        marker.stringValue = markerText
        marker.textColor = markerColor
        content.attributedStringValue = Self.contentText(for: line, language: language)
        needsDisplay = true
    }

    func updateCodeViewport(horizontalOffset: CGFloat, contentWidth: CGFloat) {
        guard self.horizontalOffset != horizontalOffset
                || codeContentWidth != contentWidth else {
            return
        }
        self.horizontalOffset = horizontalOffset
        codeContentWidth = contentWidth
        needsLayout = true
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
        case .keyword: AgentGitPalette.syntaxKeyword
        case .string: AgentGitPalette.syntaxString
        case .number: AgentGitPalette.syntaxNumber
        case .comment: AgentGitPalette.syntaxComment
        case .heading: AgentGitPalette.syntaxHeading
        }
    }

    private static func inlineHighlight(for kind: GitDiffLineKind) -> NSColor? {
        switch kind {
        case .addition: AgentGitPalette.additionInline
        case .deletion: AgentGitPalette.deletionInline
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
        case .addition: AgentGitPalette.additionText
        case .deletion: AgentGitPalette.deletionText
        case .metadata: .secondaryLabelColor
        case .context: .clear
        }
    }

    private var backgroundColor: NSColor {
        switch kind {
        case .addition: AgentGitPalette.additionBackground
        case .deletion: AgentGitPalette.deletionBackground
        case .metadata: AgentGitPalette.metadataBackground
        case .context: AgentGitPalette.canvas
        }
    }
}

private final class DiffSideBySideCellView: NSTableCellView, DiffCodeViewport {
    static let identifier = NSUserInterfaceItemIdentifier("diff-side-by-side")

    private let oldPane = DiffSideLinePane(side: .old)
    private let newPane = DiffSideLinePane(side: .new)
    private let divider = NSBox()
    private var renderedPair: GitDiffLinePair?
    private var renderedLanguage: GitSyntaxLanguage?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(oldPane)
        addSubview(newPane)
        divider.boxType = .separator
        addSubview(divider)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        let paneWidth = bounds.width / 2
        oldPane.frame = NSRect(x: 0, y: 0, width: paneWidth, height: bounds.height)
        newPane.frame = NSRect(
            x: paneWidth,
            y: 0,
            width: paneWidth,
            height: bounds.height
        )
        divider.frame = NSRect(
            x: paneWidth - 0.5,
            y: 0,
            width: 1,
            height: bounds.height
        )
    }

    func update(pair: GitDiffLinePair, language: GitSyntaxLanguage) {
        guard renderedPair != pair || renderedLanguage != language else {
            return
        }
        renderedPair = pair
        renderedLanguage = language
        oldPane.update(line: pair.old, language: language)
        newPane.update(line: pair.new, language: language)
        needsLayout = true
        needsDisplay = true
    }

    func updateCodeViewport(horizontalOffset: CGFloat, contentWidth: CGFloat) {
        oldPane.updateCodeViewport(
            horizontalOffset: horizontalOffset,
            contentWidth: contentWidth
        )
        newPane.updateCodeViewport(
            horizontalOffset: horizontalOffset,
            contentWidth: contentWidth
        )
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
        selectable: true
    )
    private let contentClip = NSView()
    private var kind: GitDiffLineKind?
    private var horizontalOffset: CGFloat = 0
    private var codeContentWidth: CGFloat = 0

    override var isFlipped: Bool { true }

    init(side: Side) {
        self.side = side
        super.init(frame: .zero)
        addSubview(lineNumber)
        addSubview(marker)
        let sideName = switch side {
        case .old: "old"
        case .new: "new"
        }
        contentClip.identifier = NSUserInterfaceItemIdentifier("diff-\(sideName)-code-clip")
        contentClip.wantsLayer = true
        contentClip.layer?.masksToBounds = true
        content.identifier = NSUserInterfaceItemIdentifier("diff-\(sideName)-code-content")
        contentClip.addSubview(content)
        addSubview(contentClip)
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
        contentClip.frame = NSRect(
            x: lineNumberWidth + markerWidth,
            y: 0,
            width: max(0, bounds.width - lineNumberWidth - markerWidth - 8),
            height: bounds.height
        )
        content.frame = NSRect(
            x: -horizontalOffset,
            y: 0,
            width: max(contentClip.bounds.width, codeContentWidth),
            height: contentClip.bounds.height
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        let fillRect = bounds.intersection(dirtyRect)
        backgroundColor.setFill()
        fillRect.fill()
        AgentGitPalette.codeGutter.setFill()
        NSRect(x: 0, y: fillRect.minY, width: 56, height: fillRect.height)
            .intersection(bounds)
            .fill()
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

    func updateCodeViewport(horizontalOffset: CGFloat, contentWidth: CGFloat) {
        guard self.horizontalOffset != horizontalOffset
                || codeContentWidth != contentWidth else {
            return
        }
        self.horizontalOffset = horizontalOffset
        codeContentWidth = contentWidth
        needsLayout = true
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
        case .addition: AgentGitPalette.additionText
        case .deletion: AgentGitPalette.deletionText
        case .metadata: .secondaryLabelColor
        case .context: .clear
        }
    }

    private var backgroundColor: NSColor {
        guard let kind else {
            return AgentGitPalette.codeFiller
        }
        return switch kind {
        case .addition: AgentGitPalette.additionBackground
        case .deletion: AgentGitPalette.deletionBackground
        case .metadata: AgentGitPalette.metadataBackground
        case .context: AgentGitPalette.canvas
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
