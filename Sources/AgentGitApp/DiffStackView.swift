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
    case openInReview
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

struct DiffStackFolder: Identifiable, Hashable {
    let id: String
    let title: String
    let isExpanded: Bool
    let fileIDs: [String]
}

struct DiffStackGroup: Identifiable, Hashable {
    let id: String
    let title: String?
    let emptyMessage: String
    let isExpanded: Bool
    let files: [DiffStackFile]
    let folders: [DiffStackFolder]

    init(
        id: String,
        title: String?,
        emptyMessage: String,
        isExpanded: Bool,
        files: [DiffStackFile],
        folders: [DiffStackFolder] = []
    ) {
        self.id = id
        self.title = title
        self.emptyMessage = emptyMessage
        self.isExpanded = isExpanded
        self.files = files
        self.folders = folders
    }
}

struct DiffStackSummary: Equatable {
    let commit: GitCommit?
    let metadata: GitCommitMetadata?
    let message: String
    let fileCount: Int
    let addedLineCount: Int
    let deletedLineCount: Int
    let isLoading: Bool
    let isPending: Bool
    let isFileListExpanded: Bool

    init(
        commit: GitCommit? = nil,
        metadata: GitCommitMetadata? = nil,
        message: String = "",
        fileCount: Int = 0,
        addedLineCount: Int = 0,
        deletedLineCount: Int = 0,
        isLoading: Bool = false,
        isPending: Bool = false,
        isFileListExpanded: Bool
    ) {
        self.commit = commit
        self.metadata = metadata
        self.message = message
        self.fileCount = fileCount
        self.addedLineCount = addedLineCount
        self.deletedLineCount = deletedLineCount
        self.isLoading = isLoading
        self.isPending = isPending
        self.isFileListExpanded = isFileListExpanded
    }
}

struct ReviewFileListExpansionBar: View {
    let isExpanded: Bool
    let onSetExpanded: (Bool) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button {
                onSetExpanded(!isExpanded)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 10)
                    Text(isExpanded ? "Collapse All" : "Expand All")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("review-file-list-toggle-all")
            .accessibilityLabel(isExpanded ? "Collapse All Files" : "Expand All Files")
            .accessibilityHint(
                isExpanded
                    ? "Collapses every folder and file diff in the list"
                    : "Expands every folder and file diff in the list"
            )

            Spacer(minLength: 0)
        }
        .font(.system(size: 12, weight: .regular))
        .padding(.horizontal, 13)
        .frame(height: 28)
        .background(Color(nsColor: AgentGitPalette.canvas))
    }
}

private struct DiffStackSummaryContent: View {
    let summary: DiffStackSummary
    let onSetAllFilesExpanded: (Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if summary.isPending {
                PendingDiffSummaryHeader(summary: summary)
                Divider()
            } else if let commit = summary.commit {
                CommitSummaryHeader(
                    commit: commit,
                    metadata: summary.metadata,
                    message: summary.message,
                    fileCount: summary.fileCount,
                    addedLineCount: summary.addedLineCount,
                    deletedLineCount: summary.deletedLineCount,
                    isLoading: summary.isLoading
                )
                Divider()
            }
            ReviewFileListExpansionBar(
                isExpanded: summary.isFileListExpanded,
                onSetExpanded: onSetAllFilesExpanded
            )
            Divider()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: AgentGitPalette.canvas))
    }
}

private struct PendingDiffSummaryHeader: View {
    let summary: DiffStackSummary

    var body: some View {
        HStack(spacing: 8) {
            Text("Pending Changes")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)

            Text(countedLabel(summary.fileCount, singular: "file"))
                .foregroundStyle(.secondary)

            Text("+\(summary.addedLineCount)")
                .foregroundStyle(Color(nsColor: AgentGitPalette.additionText))
            Text("−\(summary.deletedLineCount)")
                .foregroundStyle(Color(nsColor: AgentGitPalette.deletionText))

            Spacer(minLength: 8)

            if summary.isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            SettingsLink {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Review settings")
            .accessibilityLabel("Review settings")
        }
        .font(.system(size: 11).monospacedDigit())
        .padding(.horizontal, 13)
        .frame(height: 44)
        .background(Color(nsColor: AgentGitPalette.canvas))
    }
}

struct DiffStackCommand: Equatable {
    enum Action: Equatable {
        case focusFile(String)
        case requestFileDiscard(String)
        case moveHunk(Int)
    }

    let id: UInt64
    let action: Action
}

/// 单个 `NSTableView` 承载整次评审的所有文件，展开只是插入行，不新建视图层级。
struct DiffStackView: NSViewRepresentable {
    let summary: DiffStackSummary?
    let groups: [DiffStackGroup]
    let layout: DiffLayoutMode
    let scrollTarget: String?
    let scrollKey: ReviewStateKey
    let scrollStore: ReviewStateStore
    let isApplicationActive: Bool
    let loadingMessage: String
    let mutationActionsEnabled: Bool
    var loadingContextGapIDs: Set<String> = []
    let command: DiffStackCommand?
    let onFocusFile: (String) -> Void
    let onToggleFile: (String) -> Void
    let onToggleGroup: (String) -> Void
    let onToggleFolder: (String) -> Void
    let onSetAllFilesExpanded: (Bool) -> Void
    let onToggleReviewed: (String) -> Void
    let onToggleWholeFile: (String) -> Void
    let onShowHunkHistory: (String, Int, Int) -> Void
    let onExpandContext: (String, String) -> Void
    let onFileUtilityAction: (String, DiffStackFileUtilityAction) -> Void
    let onFileAction: (String, GitPendingSelectionAction) -> Void
    let onSelectionAction: (String, Set<GitDiffLine.ID>, GitPendingSelectionAction) -> Void
    var canStashAll = true
    var onAllChangesAction: ((GitAllChangesAction) -> Void)? = nil

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
        scrollView.onToggleFolder = onToggleFolder
        scrollView.onSetAllFilesExpanded = onSetAllFilesExpanded
        scrollView.onToggleReviewed = onToggleReviewed
        scrollView.onToggleWholeFile = onToggleWholeFile
        scrollView.onShowHunkHistory = onShowHunkHistory
        scrollView.onExpandContext = onExpandContext
        scrollView.onFileUtilityAction = onFileUtilityAction
        scrollView.onFileAction = onFileAction
        scrollView.onSelectionAction = onSelectionAction
        scrollView.onAllChangesAction = onAllChangesAction
        scrollView.canStashAll = canStashAll
        scrollView.bind(store: scrollStore, key: scrollKey)
        scrollView.isApplicationActive = isApplicationActive
        scrollView.loadingMessage = loadingMessage
        scrollView.mutationActionsEnabled = mutationActionsEnabled
        scrollView.loadingContextGapIDs = loadingContextGapIDs
        scrollView.display(
            summary: summary,
            groups: groups,
            layout: layout,
            scrollTarget: scrollTarget
        )
        scrollView.perform(command)
    }
}

final class DiffStackScrollView: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    private enum Metrics {
        static let lineHeight: CGFloat = 20
        static let hunkHeight: CGFloat = 30
        static let imageHeight: CGFloat = 360
        static let contextEdgeHeight: CGFloat = 22
        static let fileContextToggleHeight: CGFloat = 22
        static let fileHeight: CGFloat = 56
        static let folderHeight: CGFloat = 24
        static let groupHeight: CGFloat = 36
        static let noteHeight: CGFloat = 30
        static let viewportAnchorBottomPadding: CGFloat = groupHeight + fileHeight
        static let unifiedCodeLeading: CGFloat = 80
        static let unifiedCodeTrailing: CGFloat = 8
        static let sideCodeLeading: CGFloat = 47
        static let sideCodeTrailing: CGFloat = 8
        static let maximumDisplayedColumns = 4_000
        static let codeCharacterWidth = ("M" as NSString).size(
            withAttributes: [
                .font: AgentGitTypography.code
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
    var onToggleFolder: ((String) -> Void)?
    var onSetAllFilesExpanded: ((Bool) -> Void)?
    var onToggleReviewed: ((String) -> Void)?
    var onToggleWholeFile: ((String) -> Void)?
    var onShowHunkHistory: ((String, Int, Int) -> Void)?
    var onExpandContext: ((String, String) -> Void)?
    var onFileUtilityAction: ((String, DiffStackFileUtilityAction) -> Void)?
    var onFileAction: ((String, GitPendingSelectionAction) -> Void)?
    var onSelectionAction: ((String, Set<GitDiffLine.ID>, GitPendingSelectionAction) -> Void)?
    var onAllChangesAction: ((GitAllChangesAction) -> Void)? {
        didSet {
            if (oldValue == nil) != (onAllChangesAction == nil) {
                updateVisibleMutationAvailability()
            }
        }
    }
    var canStashAll = true {
        didSet { updateVisibleMutationAvailability() }
    }
    var isApplicationActive = true {
        didSet {
            guard isApplicationActive != oldValue else {
                return
            }
            if !isApplicationActive, let scrollKey {
                inactiveScrollAnchor = (
                    key: scrollKey,
                    offset: contentView.bounds.minY
                )
                scrollStore?.saveScrollOffset(contentView.bounds.minY, for: scrollKey)
            } else if let anchor = inactiveScrollAnchor {
                inactiveScrollAnchor = nil
                if anchor.key == scrollKey {
                    restoreVerticalOffset(anchor.offset)
                }
            }
            updateVisibleImagePreviews()
        }
    }
    var mutationActionsEnabled = true {
        didSet {
            guard mutationActionsEnabled != oldValue else {
                return
            }
            updateVisibleMutationAvailability()
        }
    }
    var loadingContextGapIDs = Set<String>() {
        didSet {
            guard loadingContextGapIDs != oldValue else {
                return
            }
            updateVisibleContextGapAvailability()
        }
    }
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
    private var rowBlocks: [DiffRowBlock] = []
    private var groupSections: [GroupSection] = []
    private var fileSections: [FileSection] = []
    private var hunkRowIndexes: [Int] = []
    private var hunkRowIndexByAnchorID: [String: Int] = [:]
    private var groupRowIndexByID: [String: Int] = [:]
    private var fileRowIndexByID: [String: Int] = [:]
    private var fileSectionIndexByID: [String: Int] = [:]
    private var hunkRowIndexesByFileID: [String: IndexSet] = [:]
    private var renderToken: DiffStackToken?
    private var filePresentationToken: DiffStackFilePresentationToken?
    private var displayedSummary: DiffStackSummary?
    private var summaryRowHeight: CGFloat = 28
    private var appliedScrollTarget: String?
    private var scrollStore: ReviewStateStore?
    private var scrollKey: ReviewStateKey?
    private var pendingRestoreOffset: CGFloat?
    private var pendingHunkAnchor: PendingHunkAnchor?
    private var pendingCodeAnchor: PendingCodeAnchor?
    private var preferredWholeFileHunkAnchorByFileID: [String: String] = [:]
    private var anchorMinimumDocumentHeight: CGFloat?
    private var layoutMode: DiffLayoutMode = .sideBySide
    private var maximumCodeColumnCountByHunkID: [String: Int] = [:]
    private var codeContentWidthByHunkID: [String: CGFloat] = [:]
    private var codeHorizontalOffsetByHunkID: [String: CGFloat] = [:]
    private var appliedViewportWidth: CGFloat?
    private var appliedCommandID: UInt64?
    private var isApplyingPresentationUpdate = false
    private var inactiveScrollAnchor: (key: ReviewStateKey, offset: CGFloat)?
    private var codeSelection: DiffCodeSelection?

    private struct PendingHunkAnchor {
        let anchorID: String
        let viewportY: CGFloat
    }

    private struct FocusedControl {
        let blockID: String
        let row: Int
        let hunkID: String?
        let childPath: [Int]
        let view: NSView
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
        updateDocumentHeight()
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
        renderToken = nil
        appliedScrollTarget = nil
        appliedCommandID = nil
        pendingHunkAnchor = nil
        pendingCodeAnchor = nil
        anchorMinimumDocumentHeight = nil
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
        case let .focusFile(fileID):
            pendingRestoreOffset = nil
            pendingCodeAnchor = nil
            pendingHunkAnchor = nil
            scroll(toFileID: fileID)
        case let .requestFileDiscard(fileID):
            _ = requestFileDiscard(fileID: fileID)
        case let .moveHunk(offset):
            moveHunk(by: offset)
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

    private func restoreVerticalOffset(_ offset: CGFloat) {
        let maxOffset = max(0, tableView.bounds.height - contentView.bounds.height)
        contentView.scroll(
            to: NSPoint(x: 0, y: min(max(0, offset), maxOffset))
        )
        reflectScrolledClipView(contentView)
        updateStickyHeader()
    }

    func display(
        summary: DiffStackSummary? = nil,
        groups: [DiffStackGroup],
        layout: DiffLayoutMode,
        scrollTarget: String?
    ) {
        let token = DiffStackToken(
            summary: summary,
            groups: groups,
            layout: layout
        )
        let nextFilePresentationToken = DiffStackFilePresentationToken(groups: groups)
        if token != renderToken {
            let previousToken = renderToken
            let previousPresentation = filePresentationToken
            let previousSelection = codeSelection
            let previousRows = rows
            let selectedRows = tableView.selectedRowIndexes
            let previousResponder = window?.firstResponder as? NSView
            let focusedControl = captureFocusedControl()
            let layoutChanged = layoutMode != layout
            let preservedOffset = contentView.bounds.minY
            let hadPendingAnchor = pendingCodeAnchor != nil
                || pendingHunkAnchor != nil
            if !hadPendingAnchor {
                anchorMinimumDocumentHeight = nil
            }
            let automaticAnchor: PendingCodeAnchor? = if !hadPendingAnchor,
                                                         pendingRestoreOffset == nil {
                captureVisibleCodeAnchor()
            } else {
                nil
            }
            if let automaticAnchor {
                pendingCodeAnchor = automaticAnchor
            }
            isApplyingPresentationUpdate = true
            if layoutMode != layout {
                codeHorizontalOffsetByHunkID = [:]
            }
            layoutMode = layout
            renderToken = token
            displayedSummary = summary
            filePresentationToken = nextFilePresentationToken
            let plan = rebuildRows(
                summary: summary, groups: groups, layout: layout,
                reusingFilesFrom: previousToken
            )
            updateSummaryRowHeight(
                for: contentView.bounds.width,
                notifiesTableView: false
            )
            updateColumnWidth(force: previousToken == nil || layoutChanged)
            if let plan {
                let presentationRows = previousPresentation.map {
                    updateFilePresentation(
                        groups: groups, changes: nextFilePresentationToken.changes(from: $0), reloadsRows: false
                    )
                } ?? IndexSet()
                let reloadRows = plan.reloadedRows.union(presentationRows).subtracting(plan.insertedRows)
                tableView.beginUpdates()
                if !plan.removedRows.isEmpty { tableView.removeRows(at: plan.removedRows, withAnimation: []) }
                if !plan.insertedRows.isEmpty { tableView.insertRows(at: plan.insertedRows, withAnimation: []) }
                tableView.endUpdates()
                if !reloadRows.isEmpty {
                    tableView.reloadData(forRowIndexes: reloadRows, columnIndexes: IndexSet(integer: 0))
                    tableView.noteHeightOfRows(withIndexesChanged: reloadRows)
                }
                tableView.selectRowIndexes(
                    mappedSelectedRows(selectedRows, from: previousRows, plan: plan),
                    byExtendingSelection: false
                )
                codeSelection = previousSelection.flatMap {
                    mappedCodeSelection($0, from: previousRows, plan: plan)
                }
            } else {
                tableView.reloadData()
                tableView.deselectAll(nil)
            }
            if let previousResponder, previousResponder.window == nil {
                window?.makeFirstResponder(tableView)
            }
            for hunkID in Array(codeHorizontalOffsetByHunkID.keys) {
                codeHorizontalOffsetByHunkID[hunkID] = min(
                    codeHorizontalOffsetByHunkID[hunkID] ?? 0, maximumCodeHorizontalOffset(for: hunkID)
                )
            }
            updateVisibleCodeViewports()
            applyCodeSelectionHighlights()
            updateDocumentHeight()
            stickyGroupID = nil
            stickyFileID = nil
            restorePendingCodeAnchor(groups: groups)
            restorePendingHunkAnchorIfPossible()
            restorePendingOffsetIfPossible()
            if let focusedControl { restoreFocusedControl(focusedControl, plan: plan) }
            let anchorStillPending = pendingCodeAnchor != nil
                || pendingHunkAnchor != nil
            if pendingRestoreOffset == nil,
               ((!hadPendingAnchor && automaticAnchor == nil)
                    || anchorStillPending) {
                restoreVerticalOffset(preservedOffset)
            }
            isApplyingPresentationUpdate = false
            updateStickyHeader()
        } else if let filePresentationToken,
                  nextFilePresentationToken != filePresentationToken {
            let changes = nextFilePresentationToken.changes(
                from: filePresentationToken
            )
            self.filePresentationToken = nextFilePresentationToken
            updateFilePresentation(
                groups: groups,
                changes: changes
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

    private func captureFocusedControl() -> FocusedControl? {
        guard let responder = window?.firstResponder as? NSView, responder !== tableView else { return nil }
        var ancestor: NSView? = responder
        var row = -1
        while let view = ancestor, view !== tableView {
            row = tableView.row(for: view)
            if row >= 0 { break }
            ancestor = view.superview
        }
        guard rows.indices.contains(row), let block = rowBlocks.first(where: { $0.rows.contains(row) }),
              let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) else { return nil }
        var child: NSView = responder
        var path: [Int] = []
        while child !== cell {
            guard let parent = child.superview, let index = parent.subviews.firstIndex(where: { $0 === child }) else { return nil }
            path.append(index)
            child = parent
        }
        let hunkID: String? = if case let .hunk(hunk) = rows[row] { hunk.anchorID } else { nil }
        return FocusedControl(blockID: block.id, row: row, hunkID: hunkID, childPath: path.reversed(), view: responder)
    }

    private func restoreFocusedControl(_ focused: FocusedControl, plan: DiffRowUpdatePlan?) {
        let mappedRow = plan?.currentRow(for: focused.row)
            ?? focused.hunkID.flatMap { hunkRowIndexByAnchorID[$0] }
            ?? rowBlocks.first(where: { $0.id == focused.blockID && $0.rows.count == 1 })?.rows.lowerBound
        guard let row = mappedRow, rows.indices.contains(row),
              var candidate = tableView.view(atColumn: 0, row: row, makeIfNecessary: true) else {
            if focused.view.window == nil { window?.makeFirstResponder(tableView) }
            return
        }
        for index in focused.childPath {
            guard candidate.subviews.indices.contains(index) else { window?.makeFirstResponder(tableView); return }
            candidate = candidate.subviews[index]
        }
        guard candidate.isKind(of: type(of: focused.view)),
              focused.view.identifier == nil || candidate.identifier == focused.view.identifier else {
            window?.makeFirstResponder(tableView)
            return
        }
        if window?.makeFirstResponder(candidate) == false { window?.makeFirstResponder(tableView) }
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        // AppKit 在行数变化的间隙里可能按旧行数回头要视图；返回 nil 而不是下标越界崩溃。
        guard rows.indices.contains(row) else {
            return nil
        }
        switch rows[row] {
        case let .summary(summary):
            let cell = reusableCell(
                DiffStackSummaryCellView.self,
                identifier: DiffStackSummaryCellView.identifier
            )
            cell.update(
                summary: summary,
                onSetAllFilesExpanded: { [weak self] isExpanded in
                    self?.onSetAllFilesExpanded?(isExpanded)
                }
            )
            return cell
        case let .group(group, count):
            let cell = reusableCell(DiffGroupCellView.self, identifier: DiffGroupCellView.identifier)
            cell.update(group: group, count: count)
            configureGroupActions(cell)
            return cell
        case let .folder(folder):
            let cell = reusableCell(
                DiffFolderCellView.self,
                identifier: DiffFolderCellView.identifier
            )
            cell.update(folder: folder)
            return cell
        case let .file(file):
            let cell = reusableCell(DiffFileCellView.self, identifier: DiffFileCellView.identifier)
            cell.update(
                file: file,
                mutationActionsEnabled: mutationActionsEnabled,
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
                mutationActionsEnabled: mutationActionsEnabled,
                isLoadingContextGap: hunk.contextGap.map {
                    loadingContextGapIDs.contains($0.id)
                } ?? false,
                contextExpandHandler: { [weak self] fileID, gap in
                    self?.handleContextExpansion(fileID: fileID, gap: gap)
                },
                wholeFileHandler: { [weak self] fileID in
                    self?.handleWholeFileToggle(
                        fileID: fileID,
                        preferredHunkAnchorID: hunk.anchorID
                    )
                },
                historyHandler: { [weak self] fileID, startLine, endLine in
                    self?.focusFile(fileID)
                    self?.onShowHunkHistory?(fileID, startLine, endLine)
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
                isLoading: loadingContextGapIDs.contains(gap.id),
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
            cell.updateRowSelection(tableView.selectedRowIndexes.contains(row))
            cell.updateCodeViewport(
                horizontalOffset: codeHorizontalOffsetByHunkID[hunkID] ?? 0,
                contentWidth: codeContentWidth(for: hunkID)
            )
            applyCodeSelectionHighlight(to: cell, row: row)
            return cell
        case let .sideBySide(pair, language, _, hunkID, _):
            let cell = reusableCell(
                DiffSideBySideCellView.self,
                identifier: DiffSideBySideCellView.identifier
            )
            cell.update(pair: pair, language: language)
            cell.updateRowSelection(tableView.selectedRowIndexes.contains(row))
            cell.updateCodeViewport(
                horizontalOffset: codeHorizontalOffsetByHunkID[hunkID] ?? 0,
                contentWidth: codeContentWidth(for: hunkID)
            )
            applyCodeSelectionHighlight(to: cell, row: row)
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

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("diff-row")
        let rowView = tableView.makeView(
            withIdentifier: identifier,
            owner: self
        ) as? DiffTableRowView ?? DiffTableRowView()
        rowView.identifier = identifier
        return rowView
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.location != NSNotFound else { return }
        for row in visible.location..<NSMaxRange(visible) {
            (tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? DiffRowSelectionCell)?
                .updateRowSelection(tableView.selectedRowIndexes.contains(row))
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        // 同 viewFor：行数变化的间隙里 AppKit 可能按旧行数来问，不能下标越界。
        guard rows.indices.contains(row) else {
            return Metrics.lineHeight
        }
        return switch rows[row] {
        case .summary: summaryRowHeight
        case .group: Metrics.groupHeight
        case .folder: Metrics.folderHeight
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
        guard rows.indices.contains(row) else {
            return false
        }
        return switch rows[row] {
        case .hunk, .line, .sideBySide: true
        case .summary, .group, .folder, .file, .fileContextToggle, .contextEdge,
             .image, .note:
            false
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

    private func rebuildRows(
        summary: DiffStackSummary?,
        groups: [DiffStackGroup],
        layout: DiffLayoutMode,
        reusingFilesFrom previousToken: DiffStackToken? = nil
    ) -> DiffRowUpdatePlan? {
        if previousToken == nil {
            codeSelection = nil
        }
        let previousRows = rows
        let previousBlocks = rowBlocks
        let previousSections = Dictionary(uniqueKeysWithValues: fileSections.map { ($0.file.id, $0) })
        let previousMaximumColumns = maximumCodeColumnCountByHunkID
        let changedFileIDs = previousToken.map {
            DiffStackToken(summary: summary, groups: groups, layout: layout).changedFileIDs(from: $0)
        }
        let layoutChangedFileIDs = previousToken.map {
            DiffStackToken(summary: summary, groups: groups, layout: layout).layoutChangedFileIDs(from: $0)
        } ?? []
        var builtBlocks: [DiffRowBlock] = []
        var builtMaximumColumns: [String: Int] = [:]
        var builtHunkRowIndexes: [Int] = []
        var builtHunkRowIndexByAnchorID: [String: Int] = [:]
        var builtHunkRowsByFileID: [String: IndexSet] = [:]
        var built: [DiffStackRow] = []
        var builtGroupSections: [GroupSection] = []
        var builtFileSections: [FileSection] = []
        var groupIndexByID: [String: Int] = [:]
        var fileIndexByID: [String: Int] = [:]
        var knownHunkIDs = Set<String>()
        built.reserveCapacity(
            Self.estimatedRowCount(for: groups) + (summary == nil ? 0 : 1)
        )

        if let summary {
            built.append(.summary(summary))
            builtBlocks.append(DiffRowBlock(id: "summary", rows: 0..<built.count))
        }

        for group in groups {
            let groupHeaderRow: Int?
            if group.title != nil {
                groupHeaderRow = built.count
                groupIndexByID[group.id] = built.count
                built.append(.group(group, count: group.files.count))
                builtBlocks.append(DiffRowBlock(id: "group:\(group.id)", rows: (built.count - 1)..<built.count))
            } else {
                groupHeaderRow = nil
            }
            guard group.isExpanded else {
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
            guard !group.files.isEmpty else {
                built.append(.note(group.emptyMessage))
                builtBlocks.append(DiffRowBlock(id: "empty:\(group.id)", rows: (built.count - 1)..<built.count))
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
            func appendFile(_ file: DiffStackFile) {
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
                builtBlocks.append(DiffRowBlock(
                    id: "file-header:\(file.id)", rows: headerRow..<(headerRow + 1), preservesSelectionWhenReloaded: true
                ))
                if changedFileIDs?.contains(file.id) == false,
                   let previous = previousSections[file.id] {
                    built.append(contentsOf: previousRows[(previous.headerRow + 1)..<previous.endRow])
                    for oldIndex in hunkRowIndexesByFileID[file.id] ?? [] {
                        let index = headerRow + oldIndex - previous.headerRow
                        guard case let .hunk(hunk) = previousRows[oldIndex] else { continue }
                        builtHunkRowIndexes.append(index)
                        builtHunkRowIndexByAnchorID[hunk.anchorID] = index
                        builtHunkRowsByFileID[file.id, default: []].insert(index)
                    }
                    for hunk in file.diff?.hunks ?? [] {
                        let id = hunkAnchorID(fileID: file.id, hunkID: hunk.id)
                        builtMaximumColumns[id] = previousMaximumColumns[id]
                    }
                } else {
                    var content: [DiffStackRow] = []
                    appendContent(of: file, layout: layout, into: &content)
                    for (offset, row) in content.enumerated() {
                        guard case let .hunk(hunk) = row else { continue }
                        let index = headerRow + 1 + offset
                        builtHunkRowIndexes.append(index)
                        builtHunkRowIndexByAnchorID[hunk.anchorID] = index
                        builtHunkRowsByFileID[file.id, default: []].insert(index)
                    }
                    builtMaximumColumns.merge(Self.maximumCodeColumnCountByHunkID(in: content)) { _, new in new }
                    built.append(contentsOf: content)
                }
                builtBlocks.append(DiffRowBlock(id: "file-content:\(file.id)", rows: (headerRow + 1)..<built.count))
                builtFileSections.append(
                    FileSection(
                        groupID: group.id,
                        headerRow: headerRow,
                        endRow: built.count,
                        file: file
                    )
                )
            }
            let filesByID = Dictionary(
                uniqueKeysWithValues: group.files.map { ($0.id, $0) }
            )
            var folderFileIDs = Set<String>()
            for folder in group.folders {
                built.append(.folder(folder))
                builtBlocks.append(DiffRowBlock(id: "folder:\(group.id):\(folder.id)", rows: (built.count - 1)..<built.count))
                folderFileIDs.formUnion(folder.fileIDs)
                guard folder.isExpanded else {
                    continue
                }
                for fileID in folder.fileIDs {
                    if let file = filesByID[fileID] {
                        appendFile(file)
                    }
                }
            }
            for file in group.files where !folderFileIDs.contains(file.id) {
                appendFile(file)
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
        rowBlocks = builtBlocks
        maximumCodeColumnCountByHunkID = builtMaximumColumns
        codeContentWidthByHunkID = maximumCodeColumnCountByHunkID.mapValues { columnCount in
            ceil(CGFloat(columnCount) * Metrics.codeCharacterWidth)
        }
        codeHorizontalOffsetByHunkID = codeHorizontalOffsetByHunkID.filter {
            knownHunkIDs.contains($0.key)
        }
        groupSections = builtGroupSections
        fileSections = builtFileSections
        hunkRowIndexes = builtHunkRowIndexes
        hunkRowIndexByAnchorID = builtHunkRowIndexByAnchorID
        hunkRowIndexesByFileID = builtHunkRowsByFileID
        groupRowIndexByID = groupIndexByID
        fileRowIndexByID = fileIndexByID
        var sectionIndexByID: [String: Int] = [:]
        for index in builtFileSections.indices {
            sectionIndexByID[builtFileSections[index].file.id] = index
        }
        fileSectionIndexByID = sectionIndexByID
        guard let changedFileIDs else { return nil }
        var changedBlockIDs = Set(changedFileIDs.map { "file-content:\($0)" })
        let previousByID = Dictionary(uniqueKeysWithValues: previousBlocks.map { ($0.id, $0) })
        for block in builtBlocks where !block.id.hasPrefix("file-content:") {
            guard let old = previousByID[block.id] else { continue }
            if !Self.metadataMatches(previousRows[old.rows.lowerBound], built[block.rows.lowerBound]) {
                changedBlockIDs.insert(block.id)
            }
        }
        var semanticRowMappings: [Int: IndexSet] = [:]
        for section in builtFileSections where layoutChangedFileIDs.contains(section.file.id) {
            guard let previous = previousSections[section.file.id] else { continue }
            var indexesByIdentity: [DiffStackRowIdentity: IndexSet] = [:]
            for row in (section.headerRow + 1)..<section.endRow {
                for identity in Self.rowIdentities(in: built[row]) {
                    indexesByIdentity[identity, default: []].insert(row)
                }
            }
            for row in (previous.headerRow + 1)..<previous.endRow {
                let mapped = Self.rowIdentities(in: previousRows[row]).reduce(into: IndexSet()) {
                    $0.formUnion(indexesByIdentity[$1] ?? [])
                }
                if !mapped.isEmpty { semanticRowMappings[row] = mapped }
            }
        }
        return DiffRowUpdatePlan(
            previous: previousBlocks,
            current: builtBlocks,
            changedIDs: changedBlockIDs,
            semanticRowMappings: semanticRowMappings
        )
    }

    private static func metadataMatches(_ old: DiffStackRow, _ new: DiffStackRow) -> Bool {
        switch (old, new) {
        case let (.summary(lhs), .summary(rhs)): return lhs == rhs
        case let (.group(lhs, oldCount), .group(rhs, newCount)):
            return lhs.id == rhs.id && lhs.title == rhs.title && lhs.isExpanded == rhs.isExpanded && oldCount == newCount
        case let (.folder(lhs), .folder(rhs)): return lhs == rhs
        case let (.note(lhs), .note(rhs)): return lhs == rhs
        case let (.file(lhs), .file(rhs)):
            return lhs.id == rhs.id && lhs.path == rhs.path && lhs.originalPath == rhs.originalPath
                && lhs.status == rhs.status && lhs.statusLabel == rhs.statusLabel
                && lhs.isExpanded == rhs.isExpanded && lhs.isFocused == rhs.isFocused && lhs.isReviewed == rhs.isReviewed
                && lhs.showsWholeFile == rhs.showsWholeFile && lhs.isLoadingWholeFile == rhs.isLoadingWholeFile
                && lhs.canToggleWholeFile == rhs.canToggleWholeFile && lhs.canOpenWorkingFile == rhs.canOpenWorkingFile
                && lhs.canOpenInVisualStudioCode == rhs.canOpenInVisualStudioCode
                && lhs.canApplyPrimaryAction == rhs.canApplyPrimaryAction && lhs.canDiscard == rhs.canDiscard
                && lhs.isMutationEnabled == rhs.isMutationEnabled && lhs.mutationSnapshotID == rhs.mutationSnapshotID
                && lhs.mutationMode == rhs.mutationMode && lhs.diff?.state == rhs.diff?.state
                && lhs.diff?.addedLineCount == rhs.diff?.addedLineCount && lhs.diff?.deletedLineCount == rhs.diff?.deletedLineCount
        default: return false
        }
    }

    @discardableResult
    private func updateFilePresentation(
        groups: [DiffStackGroup],
        changes: [DiffStackFilePresentationToken.Change],
        reloadsRows: Bool = true
    ) -> IndexSet {
        guard !changes.isEmpty else {
            return []
        }
        let filesByID = Dictionary(
            uniqueKeysWithValues: groups.flatMap(\.files).map { ($0.id, $0) }
        )
        let preservedOffset = contentView.bounds.minY
        let wasApplyingPresentationUpdate = isApplyingPresentationUpdate
        isApplyingPresentationUpdate = true
        defer {
            if reloadsRows { restoreVerticalOffset(preservedOffset) }
            isApplyingPresentationUpdate = wasApplyingPresentationUpdate
        }
        var changedRows = IndexSet()
        for change in changes {
            let fileID = change.fileID
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
            let granularMutationMode = updated.status == .conflicted
                ? nil
                : updated.mutationMode
            if change.updatesHunkRows {
                for rowIndex in hunkRowIndexesByFileID[fileID] ?? [] {
                    guard rows.indices.contains(rowIndex),
                          case let .hunk(hunk) = rows[rowIndex] else {
                        continue
                    }
                    rows[rowIndex] = .hunk(
                        DiffStackHunkRow(
                            anchorID: hunk.anchorID,
                            contextGap: hunk.contextGap,
                            title: hunk.title,
                            location: hunk.location,
                            rawHeader: hunk.rawHeader,
                            layout: hunk.layout,
                            fileID: hunk.fileID,
                            lineIDs: hunk.lineIDs,
                            historyStartLine: hunk.historyStartLine,
                            historyEndLine: hunk.historyEndLine,
                            mutationMode: granularMutationMode,
                            isMutationEnabled: updated.isMutationEnabled,
                            mutationSnapshotID: updated.mutationSnapshotID,
                            showsWholeFile: updated.showsWholeFile,
                            isLoadingWholeFile: updated.isLoadingWholeFile,
                            canToggleWholeFile: updated.canToggleWholeFile
                        )
                    )
                    changedRows.insert(rowIndex)
                }
            }
            if change.updatesLineRows,
               let sectionIndex = fileSectionIndexByID[fileID] {
                let section = fileSections[sectionIndex]
                for rowIndex in (section.headerRow + 1)..<section.endRow {
                    guard rows.indices.contains(rowIndex) else {
                        continue
                    }
                    switch rows[rowIndex] {
                    case let .line(line, language, candidateFileID, hunkID, _):
                        rows[rowIndex] = .line(
                            line,
                            language,
                            fileID: candidateFileID,
                            hunkID: hunkID,
                            mutationMode: granularMutationMode
                        )
                    case let .sideBySide(
                        pair,
                        language,
                        candidateFileID,
                        hunkID,
                        _
                    ):
                        rows[rowIndex] = .sideBySide(
                            pair,
                            language,
                            fileID: candidateFileID,
                            hunkID: hunkID,
                            mutationMode: granularMutationMode
                        )
                    case .summary, .group, .folder, .file, .fileContextToggle,
                         .hunk, .contextEdge, .image, .note:
                        break
                    }
                }
            }
        }
        if reloadsRows, !changedRows.isEmpty {
            tableView.reloadData(
                forRowIndexes: changedRows,
                columnIndexes: IndexSet(integer: 0)
            )
        }
        if let stickyFileID,
           changes.contains(where: { $0.fileID == stickyFileID }),
           let updated = filesByID[stickyFileID] {
            stickyFileHeader.update(
                file: updated,
                mutationActionsEnabled: mutationActionsEnabled
            )
        }
        return changedRows
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
        if let imageDiff = file.imageDiff {
            rows.append(.image(imageDiff))
            return
        }
        guard !diff.hunks.isEmpty else {
            rows.append(.note(diff.state.note ?? "No textual changes"))
            return
        }

        let language = GitSyntaxLanguage(path: file.path)
        // 纯新增或纯删除的文件在 split 下有一整栏永远是空的，等于白扔半个窗口宽度。
        // 这种文件按 unified 排，代码能用满宽度；有增有删的文件仍然左右对照。
        let layout = effectiveDiffLayout(layout, for: diff)
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
            let historyStartLine = hunk.newCount > 0
                ? hunk.newStart
                : hunk.oldStart
            let historyLineCount = max(
                1,
                hunk.newCount > 0 ? hunk.newCount : hunk.oldCount
            )
            rows.append(
                .hunk(
                    DiffStackHunkRow(
                        anchorID: anchorID,
                        contextGap: (gap?.hiddenLineCount ?? 0) > 0 ? gap : nil,
                        title: Self.hunkTitle(hunk),
                        location: Self.hunkLocation(hunk),
                        rawHeader: hunk.header,
                        layout: layout,
                        fileID: file.id,
                        lineIDs: changedLineIDs,
                        historyStartLine: historyStartLine,
                        historyEndLine: historyStartLine + historyLineCount - 1,
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
        return ""
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
            total + 1 + group.folders.count + group.files.reduce(0) { fileTotal, file in
                guard file.isExpanded, let diff = file.diff else {
                    return fileTotal + 1
                }
                if file.imageDiff != nil {
                    return fileTotal + 2
                }
                return fileTotal + 1
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
            case .summary, .group, .folder, .file, .fileContextToggle, .hunk,
                 .contextEdge, .image, .note:
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
        let groupHeight: CGFloat = fileSectionIndexByID[fileID].flatMap { index in
            groupSections.first { $0.group.id == fileSections[index].groupID }
        } == nil ? 0 : Metrics.groupHeight
        // 真实文件头放在吸顶分组标题下面，确认按钮和第一段代码都能看到。
        let maxOffset = max(0, tableView.bounds.height - contentView.bounds.height)
        let target = NSPoint(x: 0, y: min(maxOffset, max(0, rect.minY - groupHeight)))
        contentView.scroll(to: target)
        reflectScrolledClipView(contentView)
        updateStickyHeader()
    }

    private func handleWholeFileToggle(
        fileID: String,
        preferredHunkAnchorID: String? = nil
    ) {
        guard let sectionIndex = fileSectionIndexByID[fileID] else {
            return
        }
        let file = fileSections[sectionIndex].file
        let targetWholeFileState = !file.showsWholeFile
        let retainedHunkAnchorID = preferredHunkAnchorID
            ?? preferredWholeFileHunkAnchorByFileID[fileID]
        focusFile(fileID)
        pendingCodeAnchor = captureCodeAnchor(
            fileID: fileID,
            targetWholeFileState: targetWholeFileState,
            preferredHunkAnchorID: retainedHunkAnchorID
        )
        anchorMinimumDocumentHeight = nil
        if targetWholeFileState {
            if let retainedHunkAnchorID {
                preferredWholeFileHunkAnchorByFileID[fileID] = retainedHunkAnchorID
            }
        } else {
            preferredWholeFileHunkAnchorByFileID.removeValue(forKey: fileID)
        }
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

    private func captureVisibleCodeAnchor() -> PendingCodeAnchor? {
        tableView.layoutSubtreeIfNeeded()
        let topY = min(
            contentView.bounds.maxY - 0.5,
            contentView.bounds.minY + 0.5
        )
        let rowIndex = tableView.row(
            at: NSPoint(x: contentView.bounds.minX + 0.5, y: topY)
        )
        guard rows.indices.contains(rowIndex) else {
            return nil
        }
        if case .summary = rows[rowIndex] {
            return nil
        }
        if let fileID = codeFileID(in: rows[rowIndex]),
           let line = representativeLine(
               in: rows[rowIndex],
               fileID: fileID
           ) {
            return makeCodeAnchor(
                rowIndex: rowIndex,
                fileID: fileID,
                line: line
            )
        }

        let visibleRange = tableView.rows(in: contentView.bounds)
        guard visibleRange.location != NSNotFound else {
            return nil
        }
        let targetY = contentView.bounds.midY
        let candidates = (visibleRange.location..<NSMaxRange(visibleRange))
            .compactMap { candidateRow -> (Int, String, GitDiffLine)? in
                guard rows.indices.contains(candidateRow),
                      let fileID = codeFileID(in: rows[candidateRow]),
                      let line = representativeLine(
                          in: rows[candidateRow],
                          fileID: fileID
                      ) else {
                    return nil
                }
                return (candidateRow, fileID, line)
            }
        let changedCandidates = candidates.filter { $0.2.kind != .context }
        guard let candidate = (changedCandidates.isEmpty ? candidates : changedCandidates)
            .min(by: { lhs, rhs in
                abs(tableView.rect(ofRow: lhs.0).minY - targetY)
                    < abs(tableView.rect(ofRow: rhs.0).minY - targetY)
            }) else {
            return nil
        }
        return makeCodeAnchor(
            rowIndex: candidate.0,
            fileID: candidate.1,
            line: candidate.2
        )
    }

    private func makeCodeAnchor(
        rowIndex: Int,
        fileID: String,
        line: GitDiffLine
    ) -> PendingCodeAnchor? {
        guard let sectionIndex = fileSectionIndexByID[fileID] else {
            return nil
        }
        return PendingCodeAnchor(
            fileID: fileID,
            oldLineNumber: line.oldLineNumber,
            newLineNumber: line.newLineNumber,
            viewportY: tableView.rect(ofRow: rowIndex).minY
                - contentView.bounds.minY,
            targetWholeFileState: fileSections[sectionIndex].file.showsWholeFile
        )
    }

    private func codeFileID(in row: DiffStackRow) -> String? {
        return switch row {
        case let .line(_, _, fileID, _, _),
             let .sideBySide(_, _, fileID, _, _):
            fileID
        case .summary, .group, .folder, .file, .fileContextToggle, .hunk,
             .contextEdge, .image, .note:
            nil
        }
    }

    private func captureCodeAnchor(
        fileID: String,
        targetWholeFileState: Bool,
        preferredHunkAnchorID: String? = nil
    ) -> PendingCodeAnchor? {
        tableView.layoutSubtreeIfNeeded()
        let targetY = contentView.bounds.midY
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
        let visibleChangedCandidates = visibleCandidates.filter {
            $0.1.kind != .context
        }
        let preferredVisibleCandidates = preferredHunkAnchorID.map { hunkID in
            visibleIndexes.compactMap { rowIndex -> (Int, GitDiffLine)? in
                guard let line = representativeLine(
                    in: rows[rowIndex],
                    fileID: fileID,
                    hunkID: hunkID
                ) else {
                    return nil
                }
                return (rowIndex, line)
            }
        } ?? []
        let visibleCandidatePool = if !preferredVisibleCandidates.isEmpty {
            preferredVisibleCandidates
        } else if !visibleChangedCandidates.isEmpty {
            visibleChangedCandidates
        } else {
            visibleCandidates
        }
        let visibleCandidate = visibleCandidatePool.min { lhs, rhs in
            abs(tableView.rect(ofRow: lhs.0).minY - targetY)
                < abs(tableView.rect(ofRow: rhs.0).minY - targetY)
        }
        let fallbackPreferredCandidate = preferredHunkAnchorID.flatMap { hunkID in
            fileSectionIndexByID[fileID].flatMap { sectionIndex in
                let section = fileSections[sectionIndex]
                return (section.headerRow..<section.endRow).lazy.compactMap {
                    rowIndex -> (Int, GitDiffLine)? in
                    guard let line = self.representativeLine(
                        in: self.rows[rowIndex],
                        fileID: fileID,
                        hunkID: hunkID
                    ) else {
                        return nil
                    }
                    return (rowIndex, line)
                }.first
            }
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
        let candidate = visibleCandidate ?? fallbackPreferredCandidate ?? fallbackCandidate
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
              file.showsWholeFile == anchor.targetWholeFileState,
              !file.isLoadingWholeFile else {
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
        let requiredDocumentHeight = max(0, desiredOffset) + contentView.bounds.height
        if requiredDocumentHeight > tableView.frame.height {
            anchorMinimumDocumentHeight = requiredDocumentHeight
            updateDocumentHeight()
        }
        let maxOffset = max(0, tableView.bounds.height - contentView.bounds.height)
        contentView.scroll(
            to: NSPoint(x: 0, y: min(max(0, desiredOffset), maxOffset))
        )
        reflectScrolledClipView(contentView)
        updateStickyHeader()
    }

    private func representativeLine(
        in row: DiffStackRow,
        fileID: String,
        hunkID: String? = nil
    ) -> GitDiffLine? {
        switch row {
        case let .line(line, _, candidateFileID, candidateHunkID, _):
            guard candidateFileID == fileID,
                  hunkID == nil || candidateHunkID == hunkID,
                  hunkID == nil || line.kind != .context,
                  line.oldLineNumber != nil || line.newLineNumber != nil else {
                return nil
            }
            return line
        case let .sideBySide(pair, _, candidateFileID, candidateHunkID, _):
            guard candidateFileID == fileID,
                  hunkID == nil || candidateHunkID == hunkID else {
                return nil
            }
            return [pair.new, pair.old].compactMap { $0 }.first {
                (hunkID == nil || $0.kind != .context)
                    && ($0.oldLineNumber != nil || $0.newLineNumber != nil)
            }
        case .summary, .group, .folder, .file, .fileContextToggle, .hunk,
             .contextEdge, .image, .note:
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
        backgroundColor = AgentGitPalette.codeBackground
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
        tableView.style = .plain
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.intercellSpacing = .zero
        tableView.rowHeight = Metrics.lineHeight
        tableView.usesAutomaticRowHeights = false
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = AgentGitPalette.codeBackground
        tableView.focusRingType = .default
        tableView.setAccessibilityLabel("Diff Review")
        tableView.setAccessibilityHelp(
            "Drag across code to select text across lines. Use Option-Up and Option-Down to navigate hunks, and Tab to move between controls."
        )
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = true
        tableView.selectionHighlightStyle = .regular
        tableView.copyTextProvider = { [weak self] selectedRows in
            self?.copyableText(for: selectedRows) ?? ""
        }
        tableView.codeSelectionHandler = { [weak self] event, textView in
            self?.beginCodeSelection(with: event, textView: textView) ?? false
        }
        tableView.clearCodeSelectionHandler = { [weak self] in
            self?.clearCodeSelection()
        }
        tableView.keepsCodeSelectionForMenu = { [weak self] row in
            self?.codeSelectionRows(containing: row) != nil
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
        cancelled = stickyGroupHeader.cancelDiscardConfirmation() || cancelled
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
            } else if let groupCell = cell as? DiffGroupCellView {
                cancelled = groupCell.cancelDiscardConfirmation() || cancelled
            } else if let hunkCell = cell as? DiffHunkCellView {
                cancelled = hunkCell.cancelDiscardConfirmation() || cancelled
            }
        }
        return cancelled
    }

    @objc private func clipViewBoundsChanged() {
        if isApplicationActive,
           !isApplyingPresentationUpdate,
           pendingRestoreOffset == nil,
           let scrollKey {
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
            configureGroupActions(stickyGroupHeader)
        } else {
            stickyGroupID = nil
            stickyGroupHeader.isHidden = true
        }

        if fileVisibleHeight > 1, let fileSection {
            if stickyFileID != fileSection.file.id {
                stickyFileID = fileSection.file.id
                stickyFileHeader.update(
                    file: fileSection.file,
                    mutationActionsEnabled: mutationActionsEnabled
                )
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
        case let .folder(folder):
            onToggleFolder?(folder.id)
            return true
        case let .file(file):
            focusFile(file.id)
            onToggleFile?(file.id)
            return true
        case let .group(group, _):
            onToggleGroup?(group.id)
            return true
        case .summary, .hunk, .line, .sideBySide, .fileContextToggle,
             .contextEdge, .image, .note:
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
        // 拖出来的跨行选区没有走表格的行选中，右键时要按选区所在的行来出菜单。
        let actionRows = codeSelectionRows(containing: clickedRow) ?? selectedRows
        let hasCodeSelection = !codeSelectionText().isEmpty
        let menu = NSMenu()
        if hasCodeSelection || !copyText(for: selectedRows).isEmpty {
            let copyItem = NSMenuItem(
                title: hasCodeSelection ? "Copy Selection" : "Copy Selected Lines",
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
                "Open in Review",
                command: .fileUtility(file.id, .openInReview),
                to: menu
            )
            menu.addItem(.separator())
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
                    isEnabled: file.isMutationEnabled && mutationActionsEnabled
                )
            }
            if mode == .working, file.canDiscard {
                addDiscardConfirmationMenuItem(
                    "Discard File",
                    command: .file(file.id, .discard),
                    to: menu,
                    isEnabled: file.isMutationEnabled && mutationActionsEnabled
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
                isEnabled: hunk.isMutationEnabled && mutationActionsEnabled
            )
            if mutationMode == .working {
                addDiscardConfirmationMenuItem(
                    "Discard Hunk",
                    command: .selection(hunk.fileID, hunk.lineIDs, .discard),
                    to: menu,
                    isEnabled: hunk.isMutationEnabled && mutationActionsEnabled
                )
            }

        case .line, .sideBySide:
            guard let selection = selectedChangedLines(
                clickedRow: clickedRow,
                selectedRows: actionRows
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

        case .summary, .group, .folder, .fileContextToggle, .contextEdge, .image,
             .note:
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
            case .summary, .group, .folder, .file, .fileContextToggle, .hunk,
                 .contextEdge, .image, .note:
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
        updateSummaryRowHeight(for: tableColumn.width)
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

    /// `notifiesTableView` 为 false 时只更新高度值，不通知 AppKit。刚 `rebuildRows` 完、
    /// 还没 `reloadData` 时行数和 `rows` 是对不上的，这时通知行高变化会让 AppKit 按旧行数
    /// 回头问 `viewFor:row:`，直接下标越界崩溃。
    private func updateSummaryRowHeight(
        for width: CGFloat,
        notifiesTableView: Bool = true
    ) {
        guard let displayedSummary else {
            summaryRowHeight = 28
            return
        }
        let nextHeight = DiffStackSummaryCellView.preferredHeight(
            for: displayedSummary,
            width: width
        )
        guard abs(nextHeight - summaryRowHeight) > 0.5 else {
            return
        }
        summaryRowHeight = nextHeight
        guard notifiesTableView,
              tableView.numberOfRows > 0,
              tableView.numberOfRows == rows.count,
              rows.first.map({
                  if case .summary = $0 { true } else { false }
              }) == true else {
            return
        }
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: 0))
    }

    /// 保留一个吸顶头高度的尾部滚动空间，使靠近文件末尾的代码在展开上下文后
    /// 仍能停在原来的视口位置。空白沿用 diff 画布，不引入额外可见行。
    private func updateDocumentHeight() {
        let rowContentHeight: CGFloat
        if tableView.numberOfRows > 0 {
            rowContentHeight = tableView.rect(
                ofRow: tableView.numberOfRows - 1
            ).maxY
        } else {
            rowContentHeight = 0
        }
        let targetHeight = max(
            max(
                contentView.bounds.height,
                rowContentHeight + Metrics.viewportAnchorBottomPadding
            ),
            anchorMinimumDocumentHeight ?? 0
        )
        guard abs(tableView.frame.height - targetHeight) > 0.5 else {
            return
        }
        tableView.setFrameSize(
            NSSize(width: tableView.frame.width, height: targetHeight)
        )
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
        case .summary, .group, .folder, .file, .fileContextToggle, .hunk,
             .contextEdge, .image, .note:
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
            case .summary, .group, .folder, .file, .fileContextToggle, .hunk,
                 .contextEdge, .image, .note:
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

    private func configureGroupActions(_ cell: DiffGroupCellView) {
        cell.setActions(enabled: mutationActionsEnabled && onAllChangesAction != nil, canStash: canStashAll) { [weak self] action in
            guard self?.mutationActionsEnabled == true else { return }
            self?.onAllChangesAction?(action)
        }
    }

    private func updateVisibleMutationAvailability() {
        configureGroupActions(stickyGroupHeader)
        stickyFileHeader.setMutationActionsEnabled(mutationActionsEnabled)
        let visibleRows = tableView.rows(in: contentView.bounds)
        guard visibleRows.location != NSNotFound else {
            return
        }
        for row in visibleRows.location..<NSMaxRange(visibleRows) {
            guard rows.indices.contains(row),
                  let cell = tableView.view(
                      atColumn: 0,
                      row: row,
                      makeIfNecessary: false
                  ) else {
                continue
            }
            if let groupCell = cell as? DiffGroupCellView {
                configureGroupActions(groupCell)
            } else if let fileCell = cell as? DiffFileCellView {
                fileCell.setMutationActionsEnabled(mutationActionsEnabled)
            } else if let hunkCell = cell as? DiffHunkCellView {
                hunkCell.setMutationActionsEnabled(mutationActionsEnabled)
            }
        }
    }

    private func updateVisibleContextGapAvailability() {
        let visibleRows = tableView.rows(in: contentView.bounds)
        guard visibleRows.location != NSNotFound else {
            return
        }
        for row in visibleRows.location..<NSMaxRange(visibleRows) {
            guard rows.indices.contains(row) else {
                continue
            }
            let view = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
            switch rows[row] {
            case let .contextEdge(gap, fileID):
                guard let cell = view as? DiffContextEdgeCellView else {
                    continue
                }
                cell.update(
                    gap: gap,
                    fileID: fileID,
                    isLoading: loadingContextGapIDs.contains(gap.id),
                    expandHandler: { [weak self] fileID, gap in
                        self?.handleContextExpansion(fileID: fileID, gap: gap)
                    }
                )
            case let .hunk(hunk):
                // 展开入口现在挂在 hunk 标题条上，加载态也要刷到那里。
                guard let gap = hunk.contextGap,
                      let cell = view as? DiffHunkCellView else {
                    continue
                }
                cell.update(
                    hunk: hunk,
                    mutationActionsEnabled: mutationActionsEnabled,
                    isLoadingContextGap: loadingContextGapIDs.contains(gap.id),
                    contextExpandHandler: { [weak self] fileID, gap in
                        self?.handleContextExpansion(fileID: fileID, gap: gap)
                    },
                    wholeFileHandler: { [weak self] fileID in
                        self?.handleWholeFileToggle(
                            fileID: fileID,
                            preferredHunkAnchorID: hunk.anchorID
                        )
                    },
                    historyHandler: { [weak self] fileID, startLine, endLine in
                        self?.focusFile(fileID)
                        self?.onShowHunkHistory?(fileID, startLine, endLine)
                    },
                    actionHandler: { [weak self] fileID, lineIDs, action in
                        self?.focusFile(fileID)
                        self?.onSelectionAction?(fileID, lineIDs, action)
                    }
                )
            default:
                continue
            }
        }
    }

    // MARK: - 跨行代码选择

    private static func codeCells(in row: DiffStackRow) -> [DiffCodeCell] {
        switch row {
        case let .line(line, _, fileID, _, _):
            return [DiffCodeCell(column: .unified, line: line, fileID: fileID)]
        case let .sideBySide(pair, _, fileID, _, _):
            return [
                pair.old.map { DiffCodeCell(column: .old, line: $0, fileID: fileID) },
                pair.new.map { DiffCodeCell(column: .new, line: $0, fileID: fileID) }
            ].compactMap { $0 }
        default:
            return []
        }
    }

    private static func rowIdentities(in row: DiffStackRow) -> Set<DiffStackRowIdentity> {
        switch row {
        case let .hunk(hunk): return [.hunk(hunk.anchorID)]
        case let .contextEdge(gap, _): return [.contextGap(gap.id)]
        case let .fileContextToggle(fileID, _, _): return [.contextToggle(fileID)]
        default: return Set(codeCells(in: row).map { .line($0.reference) })
        }
    }

    private func mappedSelectedRows(
        _ selectedRows: IndexSet,
        from previousRows: [DiffStackRow],
        plan: DiffRowUpdatePlan
    ) -> IndexSet {
        guard !selectedRows.isEmpty else { return [] }
        let selectedReferences = Set(selectedRows.flatMap { row in
            previousRows.indices.contains(row) ? Self.codeCells(in: previousRows[row]).map(\.reference) : []
        })
        let candidates = selectedRows.reduce(into: IndexSet()) {
            $0.formUnion(plan.currentRows(for: $1))
        }
        // 单栏中的一条删除行变成双栏时，配对的新增行可能没被选中。
        // 表格只能选择整行，只有该行所有代码都在旧选区内时才保留行选择。
        return IndexSet(candidates.filter { row in
            rows.indices.contains(row)
                && Self.codeCells(in: rows[row]).allSatisfy { selectedReferences.contains($0.reference) }
        })
    }

    private func selectedCodeSpans(
        for selection: DiffCodeSelection,
        in sourceRows: [DiffStackRow]
    ) -> [DiffCodeSelectionSpan] {
        if let preservedSpans = selection.preservedSpans { return preservedSpans }
        return (selection.startRow...selection.endRow).compactMap { row in
            guard sourceRows.indices.contains(row),
                  let cell = Self.codeCells(in: sourceRows[row]).first(where: { $0.column == selection.column }) else {
                return nil
            }
            let length = (displayText(of: cell.line) as NSString).length
            return DiffCodeSelectionSpan(
                row: row,
                column: cell.column,
                preferredColumn: cell.column,
                range: selection.range(inRow: row, column: cell.column, length: length)
            )
        }
    }

    private func mappedCodeSelection(
        _ selection: DiffCodeSelection,
        from previousRows: [DiffStackRow],
        plan: DiffRowUpdatePlan
    ) -> DiffCodeSelection? {
        if selection.preservedSpans == nil,
           plan.preservesRows(in: selection.startRow...selection.endRow),
           let anchorRow = plan.currentRow(for: selection.anchorRow),
           let focusRow = plan.currentRow(for: selection.focusRow) {
            var mapped = selection
            mapped.anchorRow = anchorRow
            mapped.focusRow = focusRow
            return mapped
        }
        let oldSpans = selectedCodeSpans(for: selection, in: previousRows)
        let references = oldSpans.compactMap { span -> DiffCodeLineReference? in
            guard previousRows.indices.contains(span.row) else { return nil }
            return Self.codeCells(in: previousRows[span.row]).first { $0.column == span.column }?.reference
        }
        guard !oldSpans.isEmpty, references.count == oldSpans.count else { return nil }
        let neededReferences = Set(references)
        var cellsByReference: [DiffCodeLineReference: [(row: Int, column: DiffCodeColumn)]] = [:]
        for row in rows.indices {
            for cell in Self.codeCells(in: rows[row]) where neededReferences.contains(cell.reference) {
                cellsByReference[cell.reference, default: []].append((row, cell.column))
            }
        }
        var mappedSpans: [DiffCodeSelectionSpan] = []
        for (span, reference) in zip(oldSpans, references) {
            let preferredColumn = span.preferredColumn == .unified
                ? (reference.kind == .deletion ? DiffCodeColumn.old : .new)
                : span.preferredColumn
            let candidates = cellsByReference[reference, default: []].filter {
                $0.column == .unified || $0.column == preferredColumn
            }
            // 找不到原行或有多个相同落点时清掉选区，避免操作相邻的新内容。
            guard candidates.count == 1, let candidate = candidates.first else { return nil }
            mappedSpans.append(
                DiffCodeSelectionSpan(
                    row: candidate.row,
                    column: candidate.column,
                    preferredColumn: span.preferredColumn,
                    range: span.range
                )
            )
        }
        let isForward = selection.anchorRow < selection.focusRow
            || (selection.anchorRow == selection.focusRow && selection.anchorIndex <= selection.focusIndex)
        guard let first = mappedSpans.first, let last = mappedSpans.last else { return nil }
        let anchor = isForward ? first : last
        let focus = isForward ? last : first
        return DiffCodeSelection(
            column: anchor.column,
            anchorRow: anchor.row,
            anchorIndex: isForward ? anchor.range.location : NSMaxRange(anchor.range),
            focusRow: focus.row,
            focusIndex: isForward ? NSMaxRange(focus.range) : focus.range.location,
            preservedSpans: mappedSpans
        )
    }

    /// 按下即建立锚点，随后自己跟踪拖拽：鼠标走到哪一行，就把选区延伸到那一行的那个字符。
    private func beginCodeSelection(
        with event: NSEvent,
        textView: DiffSelectableTextView
    ) -> Bool {
        let row = tableView.row(
            at: tableView.convert(event.locationInWindow, from: nil)
        )
        guard rows.indices.contains(row),
              let column = codeColumn(of: textView, atRow: row) else {
            return false
        }
        focusFile(atRow: row)
        window?.makeFirstResponder(tableView)
        tableView.deselectAll(nil)
        let index = textView.characterIndex(forWindowPoint: event.locationInWindow)
        if event.modifierFlags.contains(.shift),
           var selection = codeSelection,
           selection.column == column,
           selection.preservedSpans == nil {
            selection.focusRow = row
            selection.focusIndex = index
            codeSelection = selection
        } else if event.clickCount >= 3 {
            codeSelection = DiffCodeSelection(
                column: column,
                anchorRow: row,
                anchorIndex: 0,
                focusRow: row,
                focusIndex: textView.textLength
            )
        } else if event.clickCount == 2 {
            let word = textView.wordRange(at: index)
            codeSelection = DiffCodeSelection(
                column: column,
                anchorRow: row,
                anchorIndex: word.location,
                focusRow: row,
                focusIndex: word.location + word.length
            )
        } else {
            codeSelection = DiffCodeSelection(
                column: column,
                anchorRow: row,
                anchorIndex: index,
                focusRow: row,
                focusIndex: index
            )
        }
        applyCodeSelectionHighlights()
        trackCodeSelectionDrag()
        return true
    }

    private func trackCodeSelectionDrag() {
        while let event = NSApp.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp],
            until: .distantFuture,
            inMode: .eventTracking,
            dequeue: true
        ) {
            guard event.type == .leftMouseDragged else {
                break
            }
            tableView.autoscroll(with: event)
            extendCodeSelection(toWindowPoint: event.locationInWindow)
        }
        if codeSelection?.isEmpty == true {
            clearCodeSelection()
        }
    }

    private func extendCodeSelection(toWindowPoint point: NSPoint) {
        guard var selection = codeSelection,
              let endpoint = codeSelectionEndpoint(
                  at: point,
                  column: selection.column
              ),
              endpoint.row != selection.focusRow
                  || endpoint.index != selection.focusIndex else {
            return
        }
        selection.focusRow = endpoint.row
        selection.focusIndex = endpoint.index
        codeSelection = selection
        applyCodeSelectionHighlights()
    }

    /// 拖出视口时行还没有实体视图，先把落点夹回可见区域，再问那一行的字符位置。
    private func codeSelectionEndpoint(
        at windowPoint: NSPoint,
        column: DiffCodeColumn
    ) -> (row: Int, index: Int)? {
        guard !rows.isEmpty else {
            return nil
        }
        var point = tableView.convert(windowPoint, from: nil)
        let visible = tableView.visibleRect
        let lowerBound = visible.minY + 1
        point.y = min(max(point.y, lowerBound), max(lowerBound, visible.maxY - 1))
        var row = tableView.row(at: point)
        if row < 0 {
            row = point.y <= visible.minY ? 0 : rows.count - 1
        }
        guard rows.indices.contains(row) else {
            return nil
        }
        guard let textView = codeTextView(atRow: row, column: column) else {
            return (row, 0)
        }
        return (row, textView.characterIndex(forWindowPoint: windowPoint))
    }

    private func codeTextView(
        atRow row: Int,
        column: DiffCodeColumn
    ) -> DiffSelectableTextView? {
        codeSelectionCell(atRow: row)?.codeTextViewsByColumn[column]
    }

    private func codeColumn(
        of textView: DiffSelectableTextView,
        atRow row: Int
    ) -> DiffCodeColumn? {
        codeSelectionCell(atRow: row)?
            .codeTextViewsByColumn
            .first { $0.value === textView }?
            .key
    }

    private func codeSelectionCell(atRow row: Int) -> DiffCodeSelectionCell? {
        tableView.view(
            atColumn: 0,
            row: row,
            makeIfNecessary: false
        ) as? DiffCodeSelectionCell
    }

    private func applyCodeSelectionHighlights() {
        let visibleRows = tableView.rows(in: tableView.visibleRect)
        guard visibleRows.location != NSNotFound else {
            return
        }
        for row in visibleRows.location..<NSMaxRange(visibleRows) {
            guard let cell = tableView.view(
                atColumn: 0,
                row: row,
                makeIfNecessary: false
            ) else {
                continue
            }
            applyCodeSelectionHighlight(to: cell, row: row)
        }
    }

    /// 行视图会被复用，装载时必须重新下发选区，否则会把上一行的高亮带过来。
    private func applyCodeSelectionHighlight(to view: NSView, row: Int) {
        guard let cell = view as? DiffCodeSelectionCell else {
            return
        }
        for (column, textView) in cell.codeTextViewsByColumn {
            textView.mouseDownHandler = { [weak self] textView, event in
                self?.beginCodeSelection(with: event, textView: textView) ?? false
            }
            textView.contextMenuHandler = { [weak self] _, event in
                self?.codeContextMenu(for: event)
            }
            let range: NSRange = if let codeSelection {
                codeSelection.range(inRow: row, column: column, length: textView.textLength)
            } else {
                NSRange(location: 0, length: 0)
            }
            textView.setHighlightRange(range)
        }
    }

    /// 右键同样直接落在文本视图上，这里换回 diff 自己的菜单。
    private func codeContextMenu(for event: NSEvent) -> NSMenu? {
        let row = tableView.row(
            at: tableView.convert(event.locationInWindow, from: nil)
        )
        guard rows.indices.contains(row) else {
            return nil
        }
        if codeSelectionRows(containing: row) == nil {
            tableView.selectRowIndexes(
                IndexSet(integer: row),
                byExtendingSelection: false
            )
        }
        return contextMenu(clickedRow: row, selectedRows: tableView.selectedRowIndexes)
    }

    private func clearCodeSelection() {
        guard codeSelection != nil else {
            return
        }
        codeSelection = nil
        applyCodeSelectionHighlights()
    }

    func codeSelectionText() -> String {
        guard let codeSelection, !codeSelection.isEmpty else {
            return ""
        }
        var parts: [String] = []
        for span in selectedCodeSpans(for: codeSelection, in: rows) {
            guard let line = codeLine(atRow: span.row, column: span.column) else {
                continue
            }
            let text = displayText(of: line) as NSString
            parts.append(
                text.substring(
                    with: span.range
                )
            )
        }
        return parts.joined(separator: "\n")
    }

    /// 选区覆盖到的代码行，用于右键菜单里对这些行做暂存 / 撤销。
    private func codeSelectionRows(containing row: Int) -> IndexSet? {
        guard let indexes = codeSelectionRowIndexes(), indexes.contains(row) else {
            return nil
        }
        return indexes
    }

    private func codeSelectionRowIndexes() -> IndexSet? {
        guard let codeSelection, !codeSelection.isEmpty else {
            return nil
        }
        var indexes = IndexSet()
        for span in selectedCodeSpans(for: codeSelection, in: rows) where span.range.length > 0 {
            indexes.insert(span.row)
        }
        return indexes.isEmpty ? nil : indexes
    }

    private func codeLine(atRow row: Int, column: DiffCodeColumn) -> GitDiffLine? {
        guard rows.indices.contains(row) else {
            return nil
        }
        switch rows[row] {
        case let .line(line, _, _, _, _):
            return column == .unified ? line : nil
        case let .sideBySide(pair, _, _, _, _):
            return switch column {
            case .old: pair.old
            case .new: pair.new
            case .unified: nil
            }
        case .summary, .group, .folder, .file, .fileContextToggle, .hunk,
             .contextEdge, .image, .note:
            return nil
        }
    }

    /// 空行显示成一个占位空格，复制时要还原成空行。
    private func displayText(of line: GitDiffLine) -> String {
        line.content.isEmpty ? "" : DiffLineCellView.displayString(for: line)
    }

    private func copyableText(for selectedRows: IndexSet) -> String {
        let selectionText = codeSelectionText()
        return selectionText.isEmpty ? copyText(for: selectedRows) : selectionText
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
            case .summary, .file, .folder, .group, .fileContextToggle,
                 .contextEdge, .image, .note:
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
        let path: String
        let originalPath: String?
        let isExpanded: Bool
        let showsWholeFile: Bool
        let contextGaps: [ContextGapEntry]
        let diffRenderID: UInt64?
        let oldImageHash: Int?
        let newImageHash: Int?
        var layout: DiffLayoutMode?
    }

    private let entries: [Entry]
    private let emptyGroups: [EmptyGroupEntry]
    private let folders: [DiffStackFolder]
    private let summary: DiffStackSummary?
    private let layout: DiffLayoutMode

    init(
        summary: DiffStackSummary?,
        groups: [DiffStackGroup],
        layout: DiffLayoutMode
    ) {
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
                        path: file.path,
                        originalPath: file.originalPath,
                        isExpanded: file.isExpanded,
                        showsWholeFile: file.showsWholeFile,
                        contextGaps: file.contextGaps.map {
                            ContextGapEntry(
                                id: $0.id,
                                hiddenLineCount: $0.hiddenLineCount,
                                revealedLineCount: $0.revealedLines.count,
                                contextRenderID: $0.revealedLines.isEmpty
                                    ? nil
                                    : $0.contextRenderID
                            )
                        },
                        diffRenderID: file.diff?.renderID,
                        oldImageHash: file.imageDiff?.oldImage?.contentHash,
                        newImageHash: file.imageDiff?.newImage?.contentHash,
                        layout: file.isExpanded && file.imageDiff == nil
                            ? file.diff.flatMap { $0.hunks.isEmpty ? nil : effectiveDiffLayout(layout, for: $0) }
                            : nil
                    )
                )
            }
        }
        self.entries = entries
        self.emptyGroups = emptyGroups
        folders = groups.flatMap(\.folders)
        self.summary = summary
        self.layout = layout
    }

    func changedFileIDs(from previous: DiffStackToken) -> Set<String> {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.entries.map { ($0.id, $0) })
        return Set(entries.compactMap { entry in
            previousByID[entry.id] != entry ? entry.id : nil
        })
    }

    func layoutChangedFileIDs(from previous: DiffStackToken) -> Set<String> {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.entries.map { ($0.id, $0) })
        return Set(entries.compactMap { entry in
            guard var old = previousByID[entry.id], old.layout != entry.layout else { return nil }
            old.layout = entry.layout
            return old == entry ? entry.id : nil
        })
    }
}

/// 只有两侧都有变更的文件需要 split；其余文件沿用 unified 的行。
private func effectiveDiffLayout(_ layout: DiffLayoutMode, for diff: GitFileDiff) -> DiffLayoutMode {
    guard layout == .sideBySide else { return layout }
    return diff.addedLineCount > 0 && diff.deletedLineCount > 0 ? .sideBySide : .unified
}

private struct DiffStackFilePresentationToken: Equatable {
    struct Change: Equatable {
        let fileID: String
        let updatesHunkRows: Bool
        let updatesLineRows: Bool
    }

    private struct HunkEntry: Equatable {
        let status: DiffStackStatus
        let isLoadingWholeFile: Bool
        let canToggleWholeFile: Bool
        let isMutationEnabled: Bool
        let mutationSnapshotID: UInt64?
        let mutationMode: DiffStackMutationMode?
    }

    private struct Entry: Equatable {
        let id: String
        let statusLabel: String
        let isFocused: Bool
        let isReviewed: Bool
        let canOpenWorkingFile: Bool
        let canOpenInVisualStudioCode: Bool
        let canApplyPrimaryAction: Bool
        let canDiscard: Bool
        let hunk: HunkEntry
    }

    private let entries: [Entry]

    init(groups: [DiffStackGroup]) {
        entries = groups.flatMap(\.files).map {
            Entry(
                id: $0.id,
                statusLabel: $0.statusLabel,
                isFocused: $0.isFocused,
                isReviewed: $0.isReviewed,
                canOpenWorkingFile: $0.canOpenWorkingFile,
                canOpenInVisualStudioCode: $0.canOpenInVisualStudioCode,
                canApplyPrimaryAction: $0.canApplyPrimaryAction,
                canDiscard: $0.canDiscard,
                hunk: HunkEntry(
                    status: $0.status,
                    isLoadingWholeFile: $0.isLoadingWholeFile,
                    canToggleWholeFile: $0.canToggleWholeFile,
                    isMutationEnabled: $0.isMutationEnabled,
                    mutationSnapshotID: $0.mutationSnapshotID?.rawValue,
                    mutationMode: $0.mutationMode
                )
            )
        }
    }

    func changes(
        from previous: DiffStackFilePresentationToken
    ) -> [Change] {
        let previousByID = Dictionary(
            uniqueKeysWithValues: previous.entries.map { ($0.id, $0) }
        )
        return entries.compactMap { entry in
            guard let previous = previousByID[entry.id],
                  previous != entry else {
                return nil
            }
            return Change(
                fileID: entry.id,
                updatesHunkRows: previous.hunk != entry.hunk,
                updatesLineRows: previous.hunk.status != entry.hunk.status
                    || previous.hunk.mutationMode != entry.hunk.mutationMode
            )
        }
    }
}

private struct DiffStackHunkRow {
    let anchorID: String
    /// 这个 hunk 上方被折叠掉的上下文。Sublime Merge 把展开入口做在 hunk 标题条左端，
    /// 而不是额外占一行，这里跟着对齐。
    let contextGap: DiffStackContextGap?
    let title: String
    let location: String
    let rawHeader: String
    let layout: DiffLayoutMode
    let fileID: String
    let lineIDs: Set<GitDiffLine.ID>
    let historyStartLine: Int
    let historyEndLine: Int
    let mutationMode: DiffStackMutationMode?
    let isMutationEnabled: Bool
    let mutationSnapshotID: DiffReviewSnapshotID?
    let showsWholeFile: Bool
    let isLoadingWholeFile: Bool
    let canToggleWholeFile: Bool
}

private enum DiffStackRow {
    case summary(DiffStackSummary)
    case group(DiffStackGroup, count: Int)
    case folder(DiffStackFolder)
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

/// 跨行选区所在的代码列：unified 只有一列，side-by-side 分左右两列，选区不跨列。
private enum DiffCodeColumn: Hashable {
    case unified
    case old
    case new
}

private struct DiffCodeLineReference: Hashable {
    let fileID: String
    let kind: GitDiffLineKind
    let oldLineNumber: Int?
    let newLineNumber: Int?
    let content: String
    let metadataLineID: GitDiffLine.ID?

    init(fileID: String, line: GitDiffLine) {
        self.fileID = fileID
        kind = line.kind
        oldLineNumber = line.oldLineNumber
        newLineNumber = line.newLineNumber
        content = line.content
        metadataLineID = line.oldLineNumber == nil && line.newLineNumber == nil ? line.id : nil
    }
}

private struct DiffCodeCell {
    let column: DiffCodeColumn
    let line: GitDiffLine
    let fileID: String

    var reference: DiffCodeLineReference {
        DiffCodeLineReference(fileID: fileID, line: line)
    }
}

private enum DiffStackRowIdentity: Hashable {
    case line(DiffCodeLineReference)
    case hunk(String)
    case contextGap(String)
    case contextToggle(String)
}

/// 布局切换后选中的代码可能分布在两列，或跳过单栏中的另一侧变更。
private struct DiffCodeSelectionSpan {
    let row: Int
    let column: DiffCodeColumn
    let preferredColumn: DiffCodeColumn
    let range: NSRange
}

@MainActor
private protocol DiffCodeSelectionCell: AnyObject {
    var codeTextViewsByColumn: [DiffCodeColumn: DiffSelectableTextView] { get }
}

/// 一次跨行选择：锚点是按下的位置，焦点跟着拖动走，按行切成各自的字符区间。
private struct DiffCodeSelection {
    let column: DiffCodeColumn
    var anchorRow: Int
    var anchorIndex: Int
    var focusRow: Int
    var focusIndex: Int
    var preservedSpans: [DiffCodeSelectionSpan]? = nil

    var isEmpty: Bool {
        if let preservedSpans { return preservedSpans.allSatisfy { $0.range.length == 0 } }
        return anchorRow == focusRow && anchorIndex == focusIndex
    }

    var startRow: Int {
        if let preservedSpans { return preservedSpans.map(\.row).min() ?? min(anchorRow, focusRow) }
        return min(anchorRow, focusRow)
    }

    var endRow: Int {
        if let preservedSpans { return preservedSpans.map(\.row).max() ?? max(anchorRow, focusRow) }
        return max(anchorRow, focusRow)
    }

    var startIndex: Int {
        if anchorRow == focusRow {
            return min(anchorIndex, focusIndex)
        }
        return anchorRow < focusRow ? anchorIndex : focusIndex
    }

    var endIndex: Int {
        if anchorRow == focusRow {
            return max(anchorIndex, focusIndex)
        }
        return anchorRow < focusRow ? focusIndex : anchorIndex
    }

    func range(inRow row: Int, column: DiffCodeColumn, length: Int) -> NSRange {
        if let preservedSpans {
            guard let span = preservedSpans.first(where: { $0.row == row && $0.column == column }) else {
                return NSRange(location: 0, length: 0)
            }
            let lower = min(span.range.location, length)
            let upper = min(NSMaxRange(span.range), length)
            return NSRange(location: lower, length: max(0, upper - lower))
        }
        guard self.column == column, row >= startRow, row <= endRow, length > 0 else {
            return NSRange(location: 0, length: 0)
        }
        let lower = row == startRow ? min(startIndex, length) : 0
        let upper = row == endRow ? min(endIndex, length) : length
        return NSRange(location: lower, length: max(0, upper - lower))
    }
}

@MainActor
func shouldToggleDiffRow(for hitView: NSView?) -> Bool {
    guard !(hitView is NSButton) else {
        return false
    }
    if let textField = hitView as? NSTextField, textField.isSelectable {
        return false
    }
    if let textView = hitView as? NSTextView, textView.isSelectable {
        return false
    }
    return true
}

/// 表格拿到键盘焦点后系统会把选中行铺成强调蓝，直接盖掉 hunk 标题文字和代码底色。
/// 选中行一律用弱化外观，diff 自己的增删色和选区色才是这块区域的主角。
private final class DiffTableRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}

private final class DiffCopyingTableView: NSTableView {
    var copyTextProvider: ((IndexSet) -> String)?
    var rowClickHandler: ((Int) -> Bool)?
    var dynamicMenuProvider: ((Int, IndexSet) -> NSMenu?)?
    var hunkNavigationHandler: ((Int) -> Bool)?
    var cancelPendingActionHandler: (() -> Bool)?
    var codeSelectionHandler: ((NSEvent, DiffSelectableTextView) -> Bool)?
    var clearCodeSelectionHandler: (() -> Void)?
    var keepsCodeSelectionForMenu: ((Int) -> Bool)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hitView = hitTest(point)
        let clickedRow = row(at: point)
        // 代码行各自是一个 NSTextView，交给它自己处理只能选中一行；这里改由表格接管，
        // 拖过多行时按行下发选区。
        if let codeView = hitView as? DiffSelectableTextView {
            if codeSelectionHandler?(event, codeView) == true {
                return
            }
            codeView.mouseDown(with: event)
            return
        }
        clearCodeSelectionHandler?()
        if let textField = hitView as? NSTextField, textField.isSelectable {
            if clickedRow >= 0 {
                _ = rowClickHandler?(clickedRow)
            }
            textField.mouseDown(with: event)
            return
        }
        if let textView = hitView as? NSTextView, textView.isSelectable {
            if clickedRow >= 0 {
                _ = rowClickHandler?(clickedRow)
            }
            textView.mouseDown(with: event)
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
        if shortcutModifiers == .option {
            if event.keyCode == 125, hunkNavigationHandler?(1) == true {
                return
            }
            if event.keyCode == 126, hunkNavigationHandler?(-1) == true {
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
        if !selectedRowIndexes.contains(clickedRow),
           keepsCodeSelectionForMenu?(clickedRow) != true {
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

private final class DiffStackSummaryCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("diff-summary")

    private var hostingView: NSHostingView<DiffStackSummaryContent>?

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        hostingView?.frame = bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        AgentGitPalette.canvas.setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
    }

    func update(
        summary: DiffStackSummary,
        onSetAllFilesExpanded: @escaping (Bool) -> Void
    ) {
        let content = DiffStackSummaryContent(
            summary: summary,
            onSetAllFilesExpanded: onSetAllFilesExpanded
        )
        if let hostingView {
            hostingView.rootView = content
        } else {
            let hostingView = NSHostingView(rootView: content)
            hostingView.setAccessibilityIdentifier("review-scroll-summary")
            addSubview(hostingView)
            self.hostingView = hostingView
        }
        needsLayout = true
    }

    static func preferredHeight(
        for summary: DiffStackSummary,
        width: CGFloat
    ) -> CGFloat {
        let hostingView = NSHostingView(
            rootView: DiffStackSummaryContent(
                summary: summary,
                onSetAllFilesExpanded: { _ in }
            )
        )
        hostingView.setFrameSize(
            NSSize(width: max(1, width), height: 1_000)
        )
        hostingView.layoutSubtreeIfNeeded()
        return max(29, ceil(hostingView.fittingSize.height))
    }
}

private final class DiffGroupCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("diff-group")

    var clickHandler: ((String) -> Void)?

    private let chevron = makeDisclosureImageView()
    private let label = DiffTextField(
        font: .systemFont(ofSize: AgentGitTypography.interfaceSize, weight: .medium),
        textColor: .labelColor,
        alignment: .left,
        selectable: false
    )
    private var groupID = ""
    private let stashButton = NSButton(title: "Stash All", target: nil, action: nil)
    private let discardButton = NSButton(title: "Discard All", target: nil, action: nil)
    private var allChangesHandler: ((GitAllChangesAction) -> Void)?
    /// 和文件、hunk 的 Discard 一样原地二次确认：第一次点击变成 Confirm，3 秒内再点才执行。
    private var discardConfirmationTimer: Timer?
    private var isConfirmingDiscard: Bool { discardConfirmationTimer != nil }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(chevron)
        addSubview(label)
        for button in [stashButton, discardButton] {
            button.bezelStyle = .inline
            button.font = .systemFont(ofSize: 11)
            button.target = self
            button.isHidden = true
            addSubview(button)
        }
        stashButton.action = #selector(stashAll)
        discardButton.action = #selector(discardAll)
        stashButton.toolTip = "Stash all staged, unstaged, and untracked files in this worktree"
        resetDiscardConfirmation()
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
        chevron.frame = NSRect(x: 14, y: (bounds.height - 13) / 2, width: 13, height: 13)
        label.frame = NSRect(
            x: 36,
            y: (bounds.height - 16) / 2,
            width: max(0, bounds.width - (groupID == "working" ? 223 : 43)),
            height: 16
        )
        stashButton.frame = NSRect(x: bounds.width - 182, y: (bounds.height - 22) / 2, width: 80, height: 22)
        discardButton.frame = NSRect(x: bounds.width - 98, y: (bounds.height - 22) / 2, width: 90, height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        AgentGitPalette.groupHeader.setFill()
        dirtyRect.fill()
        AgentGitPalette.separator.withAlphaComponent(0.55).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        super.draw(dirtyRect)
    }

    func update(group: DiffStackGroup, count: Int) {
        if groupID != group.id {
            resetDiscardConfirmation()
        }
        groupID = group.id
        stashButton.isHidden = groupID != "working"
        discardButton.isHidden = groupID != "working"
        chevron.image = disclosureImage(isExpanded: group.isExpanded)
        label.attributedStringValue = NSAttributedString(
            string: "\(group.title ?? "") · \(count)",
            attributes: [
                .font: NSFont.systemFont(
                    ofSize: 12,
                    weight: .semibold
                ),
                .foregroundColor: AgentGitPalette.commitPrimaryText
            ]
        )
        toolTip = group.isExpanded
            ? "Collapse all \(countedLabel(count, singular: "file"))"
            : "Expand all \(countedLabel(count, singular: "file"))"
        needsLayout = true
        needsDisplay = true
    }

    func setActions(enabled: Bool, canStash: Bool, handler: @escaping (GitAllChangesAction) -> Void) {
        allChangesHandler = handler
        stashButton.isEnabled = enabled && canStash
        discardButton.isEnabled = enabled
        if !enabled {
            resetDiscardConfirmation()
        }
    }

    @objc private func stashAll() {
        resetDiscardConfirmation()
        allChangesHandler?(.stash)
    }

    @objc private func discardAll() {
        guard isConfirmingDiscard else {
            beginDiscardConfirmation()
            return
        }
        resetDiscardConfirmation()
        allChangesHandler?(.discard)
    }

    func cancelDiscardConfirmation() -> Bool {
        guard isConfirmingDiscard else {
            return false
        }
        resetDiscardConfirmation()
        return true
    }

    private func beginDiscardConfirmation() {
        resetDiscardConfirmation()
        discardButton.attributedTitle = NSAttributedString(
            string: "Confirm",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: AgentGitPalette.reviewActionConfirmationText
            ]
        )
        discardButton.toolTip = "Press again to discard staged, unstaged, and untracked files; recovery copies and a staged patch are saved in Trash"
        discardButton.setAccessibilityLabel("Confirm Discard All")
        let timer = Timer(timeInterval: 3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.resetDiscardConfirmation() }
        }
        discardConfirmationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func resetDiscardConfirmation() {
        discardConfirmationTimer?.invalidate()
        discardConfirmationTimer = nil
        discardButton.title = "Discard All"
        discardButton.toolTip = "Discard all uncommitted changes in this worktree; requires confirmation and saves recovery copies in Trash"
        discardButton.setAccessibilityLabel("Discard All")
    }
}

private final class DiffFolderCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("diff-folder")

    private let chevron = makeDisclosureImageView()
    private let icon = NSImageView()
    private let label = DiffTextField(
        font: .systemFont(ofSize: AgentGitTypography.interfaceSize, weight: .regular),
        textColor: .secondaryLabelColor,
        alignment: .left,
        selectable: false
    )

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(chevron)
        icon.imageScaling = .scaleProportionallyDown
        icon.contentTintColor = .secondaryLabelColor
        addSubview(icon)
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        chevron.frame = NSRect(x: 17, y: 7, width: 13, height: 13)
        icon.frame = NSRect(x: 36, y: 6, width: 15, height: 15)
        label.frame = NSRect(
            x: 57,
            y: 6,
            width: max(0, bounds.width - 69),
            height: 16
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        AgentGitPalette.folderHeader.setFill()
        dirtyRect.fill()
        AgentGitPalette.separator.withAlphaComponent(0.55).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        super.draw(dirtyRect)
    }

    func update(folder: DiffStackFolder) {
        chevron.image = disclosureImage(isExpanded: folder.isExpanded)
        icon.image = NSImage(
            systemSymbolName: folder.isExpanded ? "folder.fill" : "folder",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        )
        label.stringValue = folder.title
        toolTip = folder.title
        setAccessibilityLabel(folder.title)
        setAccessibilityHelp(folder.isExpanded ? "Collapse folder" : "Expand folder")
        needsLayout = true
        needsDisplay = true
    }
}

private final class ReviewGlyphButton: NSButton {
    private var isHovered = false

    override var acceptsFirstResponder: Bool { isEnabled && !isHidden }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        needsDisplay = true
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        needsDisplay = true
        return accepted
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .inline
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { nil }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        if isEnabled && (isHovered || isHighlighted || state == .on) {
            (isHighlighted ? AgentGitPalette.inputBackground : AgentGitPalette.reviewHover).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
        if window?.firstResponder === self {
            NSColor.controlAccentColor.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 5, yRadius: 5)
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }
}

private final class ReviewActionButton: NSButton {
    static let height: CGFloat = 24
    static let spacing: CGFloat = 6
    static let discardWidth: CGFloat = 78
    var isConfirming = false { didSet { needsDisplay = true } }
    var isPrimary = false { didSet { needsDisplay = true } }
    var isDestructive = false { didSet { needsDisplay = true } }
    private var isHovered = false

    var preferredWidth: CGFloat {
        let textWidth = (title as NSString).size(withAttributes: [
            .font: font ?? .systemFont(ofSize: 11.5, weight: .medium)
        ]).width
        let imageWidth: CGFloat = image == nil ? 0 : 19
        return max(28, ceil(textWidth) + imageWidth + 16)
    }

    override var acceptsFirstResponder: Bool { isEnabled && !isHidden }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        needsDisplay = true
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        needsDisplay = true
        return accepted
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .inline
        controlSize = .small
        focusRingType = .none
        font = .systemFont(ofSize: 11.5, weight: .medium)
        imagePosition = .imageLeft
        imageScaling = .scaleProportionallyDown
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { nil }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let danger = isEnabled && (isConfirming || (isDestructive && isHovered))
        let foreground = danger ? AgentGitPalette.reviewActionConfirmationText
            : isPrimary ? NSColor.controlAccentColor : AgentGitPalette.commitSecondaryText
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        if danger {
            AgentGitPalette.reviewActionConfirmationBackground.setFill()
            shape.fill()
        } else if isEnabled && (isHovered || isHighlighted) {
            let background = isPrimary
                ? NSColor.controlAccentColor.withAlphaComponent(isHighlighted ? 0.16 : 0.09)
                : isHighlighted ? AgentGitPalette.inputBackground : AgentGitPalette.reviewHover
            background.setFill()
            shape.fill()
        }
        if isEnabled && isConfirming {
            foreground.withAlphaComponent(0.3).setStroke()
            shape.lineWidth = 0.7
            shape.stroke()
        }
        contentTintColor = isEnabled ? foreground : .tertiaryLabelColor
        super.draw(dirtyRect)
        if window?.firstResponder === self {
            NSColor.controlAccentColor.setStroke()
            shape.lineWidth = 1.5
            shape.stroke()
        }
    }
}

private final class DiffFileStatsView: NSView {
    private var addedLineCount: Int?
    private var deletedLineCount: Int?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("file-diff-stats")
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(diff: GitFileDiff?) {
        addedLineCount = diff?.addedLineCount
        deletedLineCount = diff?.deletedLineCount
        if let diff {
            setAccessibilityLabel(
                countedLabel(
                    diff.deletedLineCount,
                    singular: "deletion",
                    plural: "deletions"
                )
                    + ", "
                    + countedLabel(
                        diff.addedLineCount,
                        singular: "addition",
                        plural: "additions"
                    )
            )
        } else {
            setAccessibilityLabel("Diff statistics loading")
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let addedLineCount, let deletedLineCount else {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(
                    ofSize: 10.5,
                    weight: .medium
                ),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]
            let text = NSAttributedString(string: "…", attributes: attributes)
            let size = text.size()
            text.draw(
                at: NSPoint(
                    x: max(0, bounds.maxX - size.width),
                    y: max(0, (bounds.height - size.height) / 2)
                )
            )
            return
        }

        let font = NSFont.monospacedDigitSystemFont(
            ofSize: 10.5,
            weight: .medium
        )
        let added = NSAttributedString(string: "+\(addedLineCount)", attributes: [.font: font, .foregroundColor: AgentGitPalette.additionText])
        let deleted = NSAttributedString(string: "−\(deletedLineCount)", attributes: [.font: font, .foregroundColor: AgentGitPalette.deletionText])
        let deletedSize = deleted.size()
        let addedSize = added.size()
        let right = bounds.width - 1
        deleted.draw(at: NSPoint(x: right - deletedSize.width, y: (bounds.height - deletedSize.height) / 2))
        added.draw(at: NSPoint(x: right - deletedSize.width - 9 - addedSize.width, y: (bounds.height - addedSize.height) / 2))
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
    private let statusIcon = NSImageView()
    private let statusText = DiffTextField(
        font: .monospacedSystemFont(ofSize: 10, weight: .bold),
        textColor: .secondaryLabelColor,
        alignment: .center,
        selectable: false
    )
    private let title = DiffTextField(
        font: .systemFont(ofSize: 13, weight: .semibold),
        textColor: .labelColor,
        alignment: .left,
        selectable: false
    )
    private let directoryLabel = DiffTextField(
        font: .systemFont(ofSize: 11, weight: .regular),
        textColor: AgentGitPalette.sidebarMetadata,
        alignment: .left,
        selectable: false
    )
    private let stats = DiffFileStatsView()
    private var statusColor = NSColor.secondaryLabelColor
    private let menuButton = ReviewGlyphButton(title: "", target: nil, action: nil)
    private let wholeFileButton = ReviewGlyphButton(title: "", target: nil, action: nil)
    private let reviewButton = ReviewGlyphButton(title: "", target: nil, action: nil)
    private let primaryButton = ReviewActionButton(title: "", target: nil, action: nil)
    private let discardButton = ReviewActionButton(
        title: "Discard",
        target: nil,
        action: nil
    )
    private var isFocused = false
    private var isExpanded = false
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
    private var fileMutationActionsEnabled = true
    private var globalMutationActionsEnabled = true
    private var isHovered = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(chevron)
        addSubview(statusIcon)
        addSubview(statusText)
        addSubview(title)
        directoryLabel.identifier = NSUserInterfaceItemIdentifier("file-directory-label")
        directoryLabel.lineBreakMode = .byTruncatingMiddle
        directoryLabel.usesSingleLineMode = false
        directoryLabel.cell?.truncatesLastVisibleLine = true
        directoryLabel.setAccessibilityElement(false)
        addSubview(directoryLabel)
        addSubview(stats)
        addSubview(menuButton)
        addSubview(wholeFileButton)
        addSubview(reviewButton)
        addSubview(primaryButton)
        addSubview(discardButton)
        configureWholeFileButton()
        configureReviewButton()
        configureMenuButton()
        configureStatusIcon()
        primaryButton.isPrimary = true
        discardButton.isDestructive = true
        discardButton.image = ReviewIcon.discard.actionImage
        configure(primaryButton, action: #selector(runPrimaryAction))
        configure(discardButton, action: #selector(runDiscardAction))
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self
            )
        )
        resetDiscardConfirmation()
        title.lineBreakMode = .byTruncatingMiddle
        title.usesSingleLineMode = false
        title.cell?.truncatesLastVisibleLine = true
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

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateActionVisibility()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateActionVisibility()
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
        // The second line holds file actions; hover never shifts either path line.
        let menuX = bounds.width - 38
        let reviewX = menuX - 31
        let trailingX = reviewX - 12
        let primaryWidth = canApplyPrimaryAction ? primaryButton.preferredWidth : 0
        let discardWidth = canDiscard ? ReviewActionButton.discardWidth : 0
        let spacing = canDiscard && canApplyPrimaryAction ? ReviewActionButton.spacing : 0
        let actionsWidth = primaryWidth + discardWidth + spacing
        let contentX = trailingX - max(94, actionsWidth)
        let wholeFileWidth: CGFloat = canToggleWholeFile ? 24 : 0
        let wholeFileX = contentX - wholeFileWidth - (canToggleWholeFile ? 6 : 0)
        chevron.frame = NSRect(x: 14, y: headerCenterY(13), width: 13, height: 13)
        statusIcon.frame = NSRect(x: 39, y: headerCenterY(18), width: 22, height: 18)
        statusText.frame = statusIcon.frame
        let textWidth = max(0, wholeFileX - 76 - 12)
        title.frame = NSRect(x: 76, y: 10, width: textWidth, height: 18)
        directoryLabel.frame = NSRect(x: 76, y: 32, width: textWidth, height: 14)
        stats.frame = NSRect(x: trailingX - 94, y: actionsWidth > 0 ? 8 : headerCenterY(20), width: 94, height: 20)
        menuButton.frame = NSRect(x: menuX, y: headerCenterY(28), width: 28, height: 28)
        reviewButton.frame = NSRect(x: reviewX, y: headerCenterY(28), width: 28, height: 28)
        wholeFileButton.frame = NSRect(x: wholeFileX, y: headerCenterY(26), width: wholeFileWidth, height: 26)
        let primaryX = trailingX - actionsWidth
        primaryButton.frame = NSRect(x: primaryX, y: 29, width: primaryWidth, height: ReviewActionButton.height)
        discardButton.frame = NSRect(x: primaryX + primaryWidth + spacing, y: 29, width: discardWidth, height: ReviewActionButton.height)
    }

    static let leadingGapHeight: CGFloat = 0

    private func headerCenterY(_ height: CGFloat) -> CGFloat {
        max(0, (bounds.height - height) / 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let background = isFocused ? AgentGitPalette.fileHeaderFocused
            : isExpanded ? AgentGitPalette.fileHeader
            : isHovered ? AgentGitPalette.reviewHover : AgentGitPalette.fileListRow
        background.setFill()
        dirtyRect.fill()
        if isFocused {
            NSColor.controlAccentColor.setFill()
            NSRect(x: 0, y: 8, width: 3, height: bounds.height - 16).fill()
        }
        statusColor.withAlphaComponent(0.09).setFill()
        NSBezierPath(roundedRect: NSRect(x: 36, y: headerCenterY(28), width: 28, height: 28), xRadius: 7, yRadius: 7).fill()
        AgentGitPalette.separator.withAlphaComponent(isExpanded ? 0.8 : 0.35).setFill()
        NSRect(x: 12, y: bounds.height - 1, width: bounds.width - 24, height: 1).fill()
        super.draw(dirtyRect)
    }

    func update(
        file: DiffStackFile,
        mutationActionsEnabled: Bool = true,
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
        if fileID != file.id { isHovered = false }
        fileID = file.id
        discardConfirmationSnapshotID = file.mutationSnapshotID
        isFocused = file.isFocused
        isExpanded = file.isExpanded
        isReviewed = file.isReviewed
        canReview = file.diff != nil
        canToggleWholeFile = file.canToggleWholeFile && file.showsWholeFile
        canApplyPrimaryAction = file.mutationMode != nil && file.canApplyPrimaryAction
        canDiscard = file.mutationMode == .working && file.canDiscard
        mutationMode = file.mutationMode
        fileMutationActionsEnabled = file.isMutationEnabled
        globalMutationActionsEnabled = mutationActionsEnabled
        self.reviewHandler = reviewHandler ?? self.reviewHandler
        self.wholeFileHandler = wholeFileHandler ?? self.wholeFileHandler
        self.actionHandler = actionHandler ?? self.actionHandler
        self.menuHandler = menuHandler ?? self.menuHandler
        chevron.image = disclosureImage(isExpanded: file.isExpanded)
        updateStatusPresentation(
            for: file.status,
            statusLabel: file.statusLabel
        )
        title.attributedStringValue = Self.titleText(
            path: file.path,
            originalPath: file.originalPath
        )
        let directory = (file.path as NSString).deletingLastPathComponent
        let originalDirectory = file.originalPath.map { ($0 as NSString).deletingLastPathComponent }
        directoryLabel.stringValue = originalDirectory.flatMap {
            $0 == directory ? nil : "\($0.isEmpty ? "Repository root" : $0)  →  \(directory.isEmpty ? "Repository root" : directory)"
        } ?? (directory.isEmpty ? "Repository root" : directory)
        title.toolTip = file.originalPath.map { "\($0) → \(file.path)" } ?? file.path
        title.setAccessibilityLabel(title.toolTip)
        stats.update(diff: file.diff)
        let wholeFileTitle: String
        if file.isLoadingWholeFile {
            wholeFileTitle = "Loading Whole File…"
        } else if file.showsWholeFile {
            wholeFileTitle = "Show Only Modified Hunks"
        } else {
            wholeFileTitle = "Show Entire File"
        }
        wholeFileButton.image = (file.showsWholeFile ? ReviewIcon.collapse : ReviewIcon.expand).image
        wholeFileButton.isHidden = !canToggleWholeFile
        wholeFileButton.isEnabled = !file.isLoadingWholeFile
        wholeFileButton.contentTintColor = file.showsWholeFile
            ? AgentGitPalette.activeControl
            : .tertiaryLabelColor
        wholeFileButton.toolTip = wholeFileTitle
        wholeFileButton.setAccessibilityLabel(wholeFileTitle)
        reviewButton.image = (file.isReviewed ? ReviewIcon.reviewed : ReviewIcon.review).image
        reviewButton.state = file.isReviewed ? .on : .off
        reviewButton.contentTintColor = file.isReviewed ? AgentGitPalette.statusAdded : AgentGitPalette.sidebarMetadata
        reviewButton.isHidden = false
        reviewButton.isEnabled = canReview
        let reviewTitle = file.isReviewed ? "Mark as Unreviewed" : "Mark as Reviewed"
        reviewButton.toolTip = reviewTitle
        reviewButton.setAccessibilityLabel(reviewTitle)
        primaryButton.title = file.mutationMode?.fileActionTitle ?? ""
        primaryButton.image = (file.mutationMode == .staged ? ReviewIcon.unstage : ReviewIcon.stage).actionImage
        primaryButton.imagePosition = .imageLeft
        discardButton.imagePosition = .imageLeft
        primaryButton.toolTip = file.status == .conflicted
            ? "Stage the file after resolving its conflict markers"
            : primaryButton.title
        updateMutationAvailability()
        updateActionVisibility()
        let pathToolTip = file.originalPath.map { "\($0) → \(file.path)" } ?? file.path
        toolTip = file.status == .conflicted
            ? "\(pathToolTip)\nResolve conflict markers in the working file, then Stage the file."
            : pathToolTip
        needsLayout = true
        needsDisplay = true
    }

    func setMutationActionsEnabled(_ isEnabled: Bool) {
        guard globalMutationActionsEnabled != isEnabled else {
            return
        }
        globalMutationActionsEnabled = isEnabled
        updateMutationAvailability()
    }

    private func updateMutationAvailability() {
        let isEnabled = fileMutationActionsEnabled
            && globalMutationActionsEnabled
        reviewButton.isEnabled = canReview && (mutationMode == nil || isEnabled)
        if !isEnabled {
            resetDiscardConfirmation()
        }
        primaryButton.isEnabled = isEnabled
        primaryButton.contentTintColor = isEnabled
            ? .labelColor
            : .tertiaryLabelColor
        discardButton.isEnabled = isEnabled
        if !isConfirmingDiscard {
            discardButton.contentTintColor = isEnabled
                ? .secondaryLabelColor
                : .tertiaryLabelColor
        }
        primaryButton.needsDisplay = true
        discardButton.needsDisplay = true
    }

    @discardableResult
    func requestDiscardAction() -> Bool {
        guard canDiscard,
              discardButton.isEnabled else {
            return false
        }
        runDiscardAction()
        return true
    }

    private func configure(_ button: NSButton, action: Selector) {
        button.target = self
        button.action = action
        button.font = .systemFont(
            ofSize: 11.5,
            weight: .medium
        )
    }

    private func configureReviewButton() {
        reviewButton.identifier = NSUserInterfaceItemIdentifier("review-toggle")
        reviewButton.target = self
        reviewButton.action = #selector(toggleReviewed)
        reviewButton.bezelStyle = .inline
        reviewButton.isBordered = false
        reviewButton.imagePosition = .imageOnly
        reviewButton.imageScaling = .scaleNone
    }

    private func configureMenuButton() {
        menuButton.identifier = NSUserInterfaceItemIdentifier("file-actions-menu")
        menuButton.target = self
        menuButton.action = #selector(showFileActions)
        menuButton.bezelStyle = .inline
        menuButton.isBordered = false
        menuButton.imagePosition = .imageOnly
        menuButton.imageScaling = .scaleNone
        menuButton.image = ReviewIcon.more.image
        menuButton.contentTintColor = .secondaryLabelColor
        menuButton.toolTip = "File Actions"
        menuButton.setAccessibilityLabel("File Actions")
    }

    private func configureStatusIcon() {
        statusIcon.identifier = NSUserInterfaceItemIdentifier("file-status-icon")
        statusIcon.imageScaling = .scaleNone
        statusIcon.wantsLayer = true
        statusIcon.layer?.cornerRadius = 3
        statusIcon.isHidden = true
        statusText.identifier = NSUserInterfaceItemIdentifier("file-status-label")
        statusText.isHidden = true
    }

    private func updateStatusPresentation(
        for status: DiffStackStatus,
        statusLabel: String
    ) {
        statusColor = Self.color(for: status)
        let configuration: (symbol: String, label: String)? = switch status {
        case .conflicted: ("exclamationmark.triangle.fill", "Conflicted File")
        case .added, .deleted, .modified, .renamed, .untracked: nil
        }
        guard let configuration else {
            statusIcon.isHidden = true
            statusIcon.image = nil
            statusIcon.setAccessibilityLabel(nil)
            statusText.isHidden = false
            statusText.stringValue = statusLabel
            statusText.textColor = Self.color(for: status)
            statusText.setAccessibilityLabel(
                status == .deleted ? "Deleted File" : nil
            )
            return
        }
        statusIcon.isHidden = false
        statusText.isHidden = true
        statusText.stringValue = ""
        statusText.setAccessibilityLabel(nil)
        statusIcon.image = NSImage(
            systemSymbolName: configuration.symbol,
            accessibilityDescription: configuration.label
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        )
        statusIcon.contentTintColor = Self.color(for: status)
        statusIcon.layer?.backgroundColor = NSColor.clear.cgColor
        statusIcon.setAccessibilityLabel(configuration.label)
    }

    private func configureWholeFileButton() {
        wholeFileButton.identifier = NSUserInterfaceItemIdentifier("whole-file-toggle")
        wholeFileButton.target = self
        wholeFileButton.action = #selector(toggleWholeFile)
        wholeFileButton.bezelStyle = .inline
        wholeFileButton.isBordered = false
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
        discardButton.isConfirming = true
        discardButton.title = "Confirm"
        discardButton.image = nil
        discardButton.contentTintColor = .systemRed
        discardButton.toolTip = "Confirm discard; a recovery copy will be saved in Trash"
        discardButton.setAccessibilityLabel("Confirm Discard File")
        discardButton.setAccessibilityHelp(
            "Press again to discard the file and save a recovery copy in Trash"
        )
        updateActionVisibility()
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
        discardButton.isConfirming = false
        discardButton.title = "Discard"
        discardButton.image = ReviewIcon.discard.actionImage
        discardButton.contentTintColor = .secondaryLabelColor
        discardButton.toolTip = "Discard file changes; saves a recovery copy in Trash"
        discardButton.setAccessibilityLabel("Discard File")
        discardButton.setAccessibilityHelp(
            "Requires confirmation and saves a recovery copy in Trash"
        )
        updateActionVisibility()
    }

    private func updateActionVisibility() {
        primaryButton.isHidden = !canApplyPrimaryAction
        discardButton.isHidden = !canDiscard
        needsLayout = true
        needsDisplay = true
    }

    private static func titleText(path: String, originalPath: String?) -> NSAttributedString {
        let name = (path as NSString).lastPathComponent
        let oldName = originalPath.map { ($0 as NSString).lastPathComponent }
        let displayed = oldName.flatMap { $0 == name ? nil : "\($0)  →  \(name)" } ?? name
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        return NSAttributedString(string: displayed, attributes: [
            .paragraphStyle: paragraph,
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: AgentGitPalette.commitPrimaryText
        ])
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
        AgentGitPalette.canvas.setFill()
        dirtyRect.fill()
        AgentGitPalette.separator.setFill()
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
        AgentGitPalette.separator.setFill()
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
        AgentGitPalette.imagePanel.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        AgentGitPalette.separator.withAlphaComponent(0.7).setStroke()
        let border = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: 6,
            yRadius: 6
        )
        border.lineWidth = 1
        border.stroke()
        AgentGitPalette.separator.withAlphaComponent(0.7).setFill()
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
        AgentGitPalette.canvas.setFill()
        dirtyRect.fill()
        let squareSize: CGFloat = 10
        AgentGitPalette.imageChecker.setFill()
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
        AgentGitPalette.hunkHeader.setFill()
        dirtyRect.fill()
        AgentGitPalette.reviewHeaderBorder.withAlphaComponent(0.7).setFill()
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
    private let icon = NSImageView()
    private let progressIndicator = NSProgressIndicator()
    private let label = DiffTextField(
        font: .systemFont(ofSize: AgentGitTypography.interfaceSize, weight: .regular),
        textColor: AgentGitPalette.reviewContextGapText,
        alignment: .left,
        selectable: false
    )
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
        button.isBordered = false
        button.title = ""
        addSubview(button)
        icon.image = NSImage(
            systemSymbolName: "arrow.up.and.down",
            accessibilityDescription: "Expand hidden context"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
        )
        icon.contentTintColor = AgentGitPalette.reviewContextGapText
        icon.imageScaling = .scaleNone
        addSubview(icon)
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        addSubview(progressIndicator)
        addSubview(label)
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

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? button : nil
    }

    override func layout() {
        super.layout()
        button.frame = bounds
        let labelSize = label.intrinsicContentSize
        let contentWidth = 12 + 5 + labelSize.width
        let contentX = floor((bounds.width - contentWidth) / 2)
        icon.frame = NSRect(
            x: contentX,
            y: floor((bounds.height - 12) / 2),
            width: 12,
            height: 12
        )
        progressIndicator.frame = icon.frame
        label.frame = NSRect(
            x: contentX + 17,
            y: floor((bounds.height - 16) / 2),
            width: labelSize.width,
            height: 16
        )
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // 平时只画一条被文字断开的细线，diff 读起来是连续的；鼠标移上来才铺成一条可点的带子。
        // 原来无论如何都铺满整行灰底加上下两条边，每两个 hunk 之间就横着一条重色带，
        // 把一个文件的 diff 视觉上切得很碎。
        if isHovered {
            AgentGitPalette.reviewContextGap.setFill()
            dirtyRect.fill()
            AgentGitPalette.separator.withAlphaComponent(0.65).setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
            NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        } else {
            AgentGitPalette.codeBackground.setFill()
            dirtyRect.fill()
            AgentGitPalette.separator.withAlphaComponent(0.5).setFill()
            let ruleY = floor(bounds.height / 2)
            let contentRect = icon.frame.union(label.frame).insetBy(dx: -8, dy: 0)
            NSRect(
                x: 0,
                y: ruleY,
                width: max(0, contentRect.minX),
                height: 1
            ).fill()
            NSRect(
                x: contentRect.maxX,
                y: ruleY,
                width: max(0, bounds.width - contentRect.maxX),
                height: 1
            ).fill()
        }
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
        isLoading: Bool,
        expandHandler: @escaping (String, DiffStackContextGap) -> Void
    ) {
        self.gap = gap
        self.fileID = fileID
        self.expandHandler = expandHandler
        let shownLineCount = min(20, gap.hiddenLineCount)
        let title: String
        if isLoading {
            title = "Loading hidden lines…"
            icon.isHidden = true
            progressIndicator.startAnimation(nil)
        } else {
            title = gap.hiddenLineCount == shownLineCount
                ? "Show \(shownLineCount) hidden lines"
                : "Show \(shownLineCount) of \(gap.hiddenLineCount) hidden lines"
            icon.isHidden = false
            progressIndicator.stopAnimation(nil)
        }
        label.stringValue = title
        button.isEnabled = !isLoading
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
        button.alphaValue = isHovered ? 1 : 0.72
        icon.alphaValue = button.alphaValue
        label.alphaValue = button.alphaValue
        needsDisplay = true
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
    /// 和 `DiffStackScrollView.Metrics.unifiedCodeLeading` 一致：unified 下代码列的起点，
    /// hunk 标题跟它对齐才不会比代码更靠左。
    static let unifiedCodeLeading: CGFloat = 80

    private static let discardConfirmationDuration: TimeInterval = 3
    static let identifier = NSUserInterfaceItemIdentifier("diff-hunk")

    private let unifiedTitle = DiffTextField(
        font: .systemFont(ofSize: 11.5, weight: .medium),
        textColor: AgentGitPalette.reviewHunkText,
        alignment: .left,
        selectable: false
    )
    private let marker = DiffTextField(
        font: AgentGitTypography.codeEmphasized,
        textColor: .tertiaryLabelColor,
        alignment: .center,
        selectable: false
    )
    private let location = DiffTextField(
        font: .monospacedSystemFont(ofSize: 10.5, weight: .regular),
        textColor: .tertiaryLabelColor,
        alignment: .right,
        selectable: false
    )
    private let paneDivider = NSBox()
    /// hunk 上方那段被折叠的上下文的展开入口。Sublime Merge 把它做在标题条左端，
    /// 不额外占一行，这里跟着对齐。
    private let contextExpandButton = NSButton(title: "", target: nil, action: nil)
    private let contextProgress = NSProgressIndicator()
    private let wholeFileButton = NSButton(title: "", target: nil, action: nil)
    private let historyButton = ReviewActionButton(
        title: "Hunk History",
        target: nil,
        action: nil
    )
    private let menuButton = ReviewActionButton(title: "", target: nil, action: nil)
    private let primaryButton = ReviewActionButton(title: "", target: nil, action: nil)
    private let discardButton = ReviewActionButton(
        title: "Discard",
        target: nil,
        action: nil
    )
    private var fileID = ""
    private var lineIDs: Set<GitDiffLine.ID> = []
    private var historyStartLine = 1
    private var historyEndLine = 1
    private var rawHeader = ""
    private var mutationMode: DiffStackMutationMode?
    private var hunkMutationActionsEnabled = true
    private var globalMutationActionsEnabled = true
    private var discardConfirmationID = ""
    private var isConfirmingDiscard = false
    private var discardConfirmationTimer: Timer?
    private var canToggleWholeFile = false
    private var showsWholeFile = false
    private var isLoadingWholeFile = false
    private var canShowHistory = false
    private var isHovered = false
    private var layoutMode: DiffLayoutMode = .unified
    private var contextGap: DiffStackContextGap?
    private var isLoadingContextGap = false
    private var contextExpandHandler: ((String, DiffStackContextGap) -> Void)?
    private var wholeFileHandler: ((String) -> Void)?
    private var historyHandler: ((String, Int, Int) -> Void)?
    private var actionHandler: ((String, Set<GitDiffLine.ID>, GitPendingSelectionAction) -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        marker.stringValue = "@@"
        marker.identifier = NSUserInterfaceItemIdentifier("hunk-marker")
        marker.setAccessibilityElement(false)
        addSubview(marker)
        unifiedTitle.identifier = NSUserInterfaceItemIdentifier("hunk-title-unified")
        addSubview(unifiedTitle)
        location.identifier = NSUserInterfaceItemIdentifier("hunk-location")
        addSubview(location)
        paneDivider.boxType = .custom
        paneDivider.borderWidth = 0
        paneDivider.fillColor = AgentGitPalette.splitPaneDivider
        addSubview(paneDivider)
        contextExpandButton.identifier = NSUserInterfaceItemIdentifier("hunk-context-expand")
        contextExpandButton.target = self
        contextExpandButton.action = #selector(expandContextGap)
        contextExpandButton.bezelStyle = .inline
        contextExpandButton.isBordered = false
        contextExpandButton.imagePosition = .imageOnly
        contextExpandButton.imageScaling = .scaleNone
        contextExpandButton.image = NSImage(
            systemSymbolName: "arrow.up.and.down",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
        )
        contextExpandButton.contentTintColor = .secondaryLabelColor
        addSubview(contextExpandButton)
        contextProgress.style = .spinning
        contextProgress.controlSize = .small
        contextProgress.isDisplayedWhenStopped = false
        addSubview(contextProgress)
        addSubview(wholeFileButton)
        addSubview(historyButton)
        addSubview(menuButton)
        addSubview(primaryButton)
        addSubview(discardButton)
        wholeFileButton.identifier = NSUserInterfaceItemIdentifier("hunk-whole-file-toggle")
        wholeFileButton.target = self
        wholeFileButton.action = #selector(toggleWholeFile)
        wholeFileButton.bezelStyle = .inline
        wholeFileButton.imagePosition = .imageOnly
        wholeFileButton.imageScaling = .scaleNone
        historyButton.identifier = NSUserInterfaceItemIdentifier("hunk-history")
        historyButton.setAccessibilityLabel("Hunk History")
        historyButton.setAccessibilityHelp(
            "Filter commit history to the lines in this hunk"
        )
        configure(historyButton, action: #selector(showHistory))
        menuButton.identifier = NSUserInterfaceItemIdentifier("hunk-actions-menu")
        menuButton.imagePosition = .imageOnly
        menuButton.imageScaling = .scaleNone
        menuButton.image = NSImage(
            systemSymbolName: "ellipsis",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        )
        menuButton.contentTintColor = .secondaryLabelColor
        menuButton.setAccessibilityLabel("Hunk Actions")
        menuButton.setAccessibilityHelp("Show actions for this hunk")
        configure(menuButton, action: #selector(showHunkMenu))
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self
            )
        )
        primaryButton.isPrimary = true
        discardButton.isDestructive = true
        discardButton.image = ReviewIcon.discard.actionImage
        configure(primaryButton, action: #selector(runPrimaryAction))
        configure(discardButton, action: #selector(runDiscardAction))
        resetDiscardConfirmation()
        unifiedTitle.lineBreakMode = .byTruncatingTail
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
        let primaryWidth = primaryButton.isHidden ? 0 : primaryButton.preferredWidth
        let discardWidth = discardButton.isHidden ? 0 : ReviewActionButton.discardWidth
        let spacing = primaryWidth > 0 && discardWidth > 0 ? ReviewActionButton.spacing : 0
        let actionsWidth = primaryWidth + discardWidth + spacing
        let showsHistoryControls = canShowHistory && isHovered
        let historyWidth: CGFloat = showsHistoryControls ? 92 : 0
        let menuWidth: CGFloat = showsHistoryControls ? 34 : 0
        let historySpacing: CGFloat = historyWidth > 0 ? 4 : 0
        let actionSpacing: CGFloat = actionsWidth > 0 && historyWidth > 0 ? 4 : 0
        let wholeFileWidth: CGFloat = canToggleWholeFile ? 24 : 0
        marker.frame = .zero
        // 展开入口占标题条最左边一格，正好落在行号列上方；整个文件的展开按钮排在它右边。
        let expandWidth: CGFloat = contextExpandButton.isHidden ? 0 : 22
        let wholeFileX: CGFloat = (contextExpandButton.isHidden ? 0 : expandWidth + 2) + 7
        let wholeFileHeight = min(24, bounds.height)
        wholeFileButton.frame = NSRect(
            x: wholeFileX,
            y: max(0, (bounds.height - wholeFileHeight) / 2),
            width: wholeFileWidth,
            height: wholeFileHeight
        )
        // unified 下标题起点对齐代码列，和 split 的行为一致；split 里 sideLabelInset 已经
        // 等于行号加符号列的宽度。
        let unifiedLabelX: CGFloat = canToggleWholeFile
            ? max(Self.unifiedCodeLeading, wholeFileButton.frame.maxX + 6)
            : Self.unifiedCodeLeading
        let sideLabelInset: CGFloat = 47
        let menuX = bounds.width - menuWidth - 9
        let historyX = menuX - historyWidth - historySpacing
        let actionX = historyX - actionsWidth - actionSpacing
        let actionHeight = min(ReviewActionButton.height, bounds.height)
        let actionY = max(0, (bounds.height - actionHeight) / 2)
        location.isHidden = isHovered || isConfirmingDiscard
            || !primaryButton.isHidden || !historyButton.isHidden || !menuButton.isHidden
        location.frame = NSRect(x: max(0, bounds.width - 154), y: (bounds.height - 16) / 2, width: 140, height: 16)
        contextExpandButton.frame = NSRect(
            x: 2,
            y: 0,
            width: expandWidth,
            height: bounds.height
        )
        contextProgress.frame = NSRect(
            x: 5,
            y: max(0, (bounds.height - 12) / 2),
            width: 12,
            height: 12
        )
        primaryButton.frame = NSRect(
            x: actionX,
            y: actionY,
            width: primaryWidth,
            height: actionHeight
        )
        discardButton.frame = NSRect(
            x: actionX + primaryWidth + spacing,
            y: actionY,
            width: discardWidth,
            height: actionHeight
        )
        historyButton.frame = NSRect(
            x: historyX,
            y: 0,
            width: historyWidth,
            height: bounds.height
        )
        menuButton.frame = NSRect(
            x: menuX,
            y: 0,
            width: menuWidth,
            height: bounds.height
        )
        let titleX = layoutMode == .sideBySide
            ? max(
                sideLabelInset,
                canToggleWholeFile ? wholeFileButton.frame.maxX + 6 : sideLabelInset
            )
            : unifiedLabelX
        unifiedTitle.frame = NSRect(
            x: titleX,
            y: max(0, (bounds.height - 16) / 2),
            width: max(0, (location.isHidden ? actionX : min(actionX, location.frame.minX)) - titleX - 8),
            height: 16
        )
        if layoutMode == .sideBySide {
            paneDivider.frame = NSRect(
                x: floor(bounds.width / 2),
                y: 0,
                width: 1,
                height: bounds.height
            )
        } else {
            paneDivider.frame = .zero
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        AgentGitPalette.hunkHeader.setFill()
        dirtyRect.fill()
        AgentGitPalette.separator.withAlphaComponent(0.3).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        super.draw(dirtyRect)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateHoverControls()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateHoverControls()
    }

    func update(
        hunk: DiffStackHunkRow,
        mutationActionsEnabled: Bool = true,
        isLoadingContextGap: Bool = false,
        contextExpandHandler: ((String, DiffStackContextGap) -> Void)? = nil,
        wholeFileHandler: ((String) -> Void)?,
        historyHandler: ((String, Int, Int) -> Void)?,
        actionHandler: ((String, Set<GitDiffLine.ID>, GitPendingSelectionAction) -> Void)?
    ) {
        contextGap = hunk.contextGap
        self.isLoadingContextGap = isLoadingContextGap
        self.contextExpandHandler = contextExpandHandler
        updateContextExpansion()
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
        // 左右两栏的 section 是同一个，画两遍等于让同一句话在一行里出现两次。
        unifiedTitle.stringValue = hunk.title
        location.stringValue = hunk.location
        unifiedTitle.toolTip = hunk.rawHeader
        layoutMode = hunk.layout
        paneDivider.isHidden = hunk.layout != .sideBySide
        fileID = hunk.fileID
        lineIDs = hunk.lineIDs
        historyStartLine = hunk.historyStartLine
        historyEndLine = hunk.historyEndLine
        rawHeader = hunk.rawHeader
        mutationMode = hunk.mutationMode
        hunkMutationActionsEnabled = hunk.isMutationEnabled
        globalMutationActionsEnabled = mutationActionsEnabled
        canToggleWholeFile = hunk.canToggleWholeFile && !hunk.showsWholeFile
        showsWholeFile = hunk.showsWholeFile
        isLoadingWholeFile = hunk.isLoadingWholeFile
        canShowHistory = hunk.mutationMode == nil
        self.wholeFileHandler = wholeFileHandler
        self.historyHandler = historyHandler
        self.actionHandler = actionHandler
        primaryButton.title = hunk.mutationMode?.hunkActionTitle ?? ""
        primaryButton.image = (hunk.mutationMode == .staged ? ReviewIcon.unstage : ReviewIcon.stage).actionImage
        primaryButton.imagePosition = .imageLeft
        discardButton.imagePosition = .imageLeft
        updateMutationAvailability()
        let wholeFileTitle: String
        let wholeFileSymbol: String
        if hunk.isLoadingWholeFile {
            wholeFileTitle = "Loading Whole File…"
            wholeFileSymbol = "ellipsis"
        } else if hunk.showsWholeFile {
            wholeFileTitle = "Show Only Modified Hunks"
            wholeFileSymbol = "rectangle.compress.vertical"
        } else {
            wholeFileTitle = "Show Entire File"
            wholeFileSymbol = "rectangle.expand.vertical"
        }
        wholeFileButton.image = NSImage(
            systemSymbolName: wholeFileSymbol,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        )
        wholeFileButton.isEnabled = !hunk.isLoadingWholeFile
        wholeFileButton.contentTintColor = hunk.showsWholeFile
            ? AgentGitPalette.activeControl
            : .secondaryLabelColor
        wholeFileButton.toolTip = wholeFileTitle
        wholeFileButton.setAccessibilityLabel(wholeFileTitle)
        updateHoverControls()
        toolTip = "\(hunk.rawHeader)\nOption-Down: Next Hunk  ·  Option-Up: Previous Hunk"
        needsLayout = true
        needsDisplay = true
    }

    func setMutationActionsEnabled(_ isEnabled: Bool) {
        guard globalMutationActionsEnabled != isEnabled else {
            return
        }
        globalMutationActionsEnabled = isEnabled
        updateMutationAvailability()
    }

    private func updateMutationAvailability() {
        let isEnabled = hunkMutationActionsEnabled
            && globalMutationActionsEnabled
        if !isEnabled {
            resetDiscardConfirmation()
        }
        primaryButton.isEnabled = isEnabled
        primaryButton.contentTintColor = isEnabled
            ? .labelColor
            : .tertiaryLabelColor
        discardButton.isEnabled = isEnabled
        if !isConfirmingDiscard {
            discardButton.contentTintColor = isEnabled
                ? .secondaryLabelColor
                : .tertiaryLabelColor
        }
        primaryButton.needsDisplay = true
        discardButton.needsDisplay = true
    }

    private func configure(_ button: NSButton, action: Selector) {
        button.target = self
        button.action = action
        button.font = .systemFont(
            ofSize: 11.5,
            weight: .medium
        )
    }

    @objc private func runPrimaryAction() {
        guard let action = mutationMode?.primaryAction else {
            return
        }
        resetDiscardConfirmation()
        actionHandler?(fileID, lineIDs, action)
    }

    private func updateContextExpansion() {
        guard let contextGap else {
            contextExpandButton.isHidden = true
            contextProgress.stopAnimation(nil)
            return
        }
        // 加载时按钮留在原位只是禁用，位置不动；转圈叠在图标上。
        contextExpandButton.isHidden = false
        contextExpandButton.isEnabled = !isLoadingContextGap
        contextExpandButton.contentTintColor = isLoadingContextGap
            ? .clear
            : .secondaryLabelColor
        if isLoadingContextGap {
            contextProgress.startAnimation(nil)
        } else {
            contextProgress.stopAnimation(nil)
        }
        let shownLineCount = min(20, contextGap.hiddenLineCount)
        let title = isLoadingContextGap
            ? "Loading hidden lines…"
            : (contextGap.hiddenLineCount == shownLineCount
                ? "Show \(shownLineCount) hidden lines"
                : "Show \(shownLineCount) of \(contextGap.hiddenLineCount) hidden lines")
        contextExpandButton.toolTip = title
        contextExpandButton.setAccessibilityLabel(title)
        contextProgress.setAccessibilityLabel("Loading hidden lines…")
        needsLayout = true
    }

    @objc private func expandContextGap() {
        guard let contextGap, !isLoadingContextGap else {
            return
        }
        contextExpandHandler?(fileID, contextGap)
    }

    @objc private func toggleWholeFile() {
        resetDiscardConfirmation()
        wholeFileHandler?(fileID)
    }

    @objc private func showHistory() {
        resetDiscardConfirmation()
        historyHandler?(fileID, historyStartLine, historyEndLine)
    }

    @objc private func showHunkMenu() {
        let menu = NSMenu()
        let history = NSMenuItem(
            title: "Hunk History",
            action: #selector(showHistory),
            keyEquivalent: ""
        )
        history.target = self
        menu.addItem(history)
        menu.addItem(.separator())
        let copyHeader = NSMenuItem(
            title: "Copy Hunk Header",
            action: #selector(copyHunkHeader),
            keyEquivalent: ""
        )
        copyHeader.target = self
        menu.addItem(copyHeader)
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: menuButton.bounds.maxY + 2),
            in: menuButton
        )
    }

    @objc private func copyHunkHeader() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(rawHeader, forType: .string)
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
        discardButton.isConfirming = true
        discardButton.title = "Confirm"
        discardButton.image = nil
        discardButton.contentTintColor = .systemRed
        discardButton.toolTip = "Confirm discard hunk; a recovery copy will be saved in Trash"
        discardButton.setAccessibilityLabel("Confirm Discard Hunk")
        discardButton.setAccessibilityHelp(
            "Press again to discard the hunk and save a recovery copy in Trash"
        )
        updateHoverControls()
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
        discardButton.isConfirming = false
        discardButton.title = "Discard"
        discardButton.image = ReviewIcon.discard.actionImage
        discardButton.contentTintColor = .secondaryLabelColor
        discardButton.toolTip = "Discard hunk changes; saves a recovery copy in Trash"
        discardButton.setAccessibilityLabel("Discard Hunk")
        discardButton.setAccessibilityHelp(
            "Requires confirmation and saves a recovery copy in Trash"
        )
        updateHoverControls()
    }

    private func updateHoverControls() {
        primaryButton.isHidden = mutationMode == nil
            || lineIDs.isEmpty
        discardButton.isHidden = mutationMode != .working
            || lineIDs.isEmpty
        wholeFileButton.isHidden = !canToggleWholeFile
        historyButton.isHidden = !canShowHistory
        menuButton.isHidden = !canShowHistory
        marker.isHidden = true
        needsLayout = true
    }
}

@MainActor
private protocol DiffCodeViewport: AnyObject {
    func updateCodeViewport(horizontalOffset: CGFloat, contentWidth: CGFloat)
}

@MainActor
private protocol DiffRowSelectionCell: AnyObject {
    func updateRowSelection(_ selected: Bool)
}

private final class DiffLineCellView: NSTableCellView, DiffCodeViewport, DiffCodeSelectionCell, DiffRowSelectionCell {
    static let identifier = NSUserInterfaceItemIdentifier("diff-line")

    var codeTextViewsByColumn: [DiffCodeColumn: DiffSelectableTextView] {
        [.unified: content]
    }

    private let oldLineNumber = DiffTextField.lineNumber()
    private let newLineNumber = DiffTextField.lineNumber()
    private let marker = DiffTextField(
        font: AgentGitTypography.code,
        textColor: .secondaryLabelColor,
        alignment: .center,
        selectable: false
    )
    private let content = DiffSelectableTextView(
        font: AgentGitTypography.code,
        textColor: AgentGitPalette.codeText
    )
    private let contentClip = NSView()
    private var kind: GitDiffLineKind = .context
    private var horizontalOffset: CGFloat = 0
    private var codeContentWidth: CGFloat = 0
    private var renderedLine: GitDiffLine?
    private var renderedLanguage: GitSyntaxLanguage?
    private var isRowSelected = false

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
        let lineNumberWidth: CGFloat = 33
        let markerWidth: CGFloat = 14
        oldLineNumber.frame = NSRect(x: 0, y: 0, width: lineNumberWidth, height: bounds.height)
        newLineNumber.frame = NSRect(
            x: lineNumberWidth,
            y: 0,
            width: lineNumberWidth,
            height: bounds.height
        )
        marker.frame = NSRect(
            x: lineNumberWidth * 2,
            y: 0,
            width: markerWidth,
            height: bounds.height
        )
        contentClip.frame = NSRect(
            x: lineNumberWidth * 2 + markerWidth,
            y: 0,
            width: max(0, bounds.width - lineNumberWidth * 2 - markerWidth - 8),
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
        if isRowSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
            dirtyRect.fill()
        }
        // 行号列不再铺灰底。代码区改成纯白之后这条灰带反而成了最显眼的东西，而且横穿增删行时
        // 会把绿红色带切断。行号靠字色区分就够了，整行底色保持连续。
        super.draw(dirtyRect)
    }

    func updateRowSelection(_ selected: Bool) {
        guard isRowSelected != selected else { return }
        isRowSelected = selected
        needsDisplay = true
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
        content.setAttributedString(Self.contentText(for: line, language: language))
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
        let font = AgentGitTypography.code
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ]

        guard line.content.utf8.count <= maximumDisplayedColumns else {
            return NSAttributedString(
                string: displayString(for: line),
                attributes: attributes
            )
        }

        let text = NSMutableAttributedString(
            string: displayString(for: line),
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

    /// 屏幕上这行实际显示的字符。跨行选区按显示字符计位置，复制也照这个取。
    fileprivate static func displayString(for line: GitDiffLine) -> String {
        guard line.content.utf8.count <= maximumDisplayedColumns else {
            return String(line.content.prefix(maximumDisplayedColumns)) + " …"
        }
        return line.content.isEmpty ? " " : line.content
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
                    value: AgentGitTypography.codeEmphasized,
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
        case .context: AgentGitPalette.codeBackground
        }
    }
}

private final class DiffSideBySideCellView: NSTableCellView, DiffCodeViewport, DiffCodeSelectionCell, DiffRowSelectionCell {
    static let identifier = NSUserInterfaceItemIdentifier("diff-side-by-side")

    var codeTextViewsByColumn: [DiffCodeColumn: DiffSelectableTextView] {
        [.old: oldPane.codeTextView, .new: newPane.codeTextView]
    }

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
        // 系统 separator 压在代码底色上几乎看不见，左右两栏会糊成一栏。
        divider.boxType = .custom
        divider.borderWidth = 0
        divider.fillColor = AgentGitPalette.splitPaneDivider
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

    func updateRowSelection(_ selected: Bool) {
        oldPane.updateRowSelection(selected)
        newPane.updateRowSelection(selected)
    }
}

private final class DiffSideLinePane: NSView {
    enum Side {
        case old
        case new
    }

    var codeTextView: DiffSelectableTextView {
        content
    }

    private let side: Side
    private let lineNumber = DiffTextField.lineNumber()
    private let marker = DiffTextField(
        font: AgentGitTypography.code,
        textColor: .secondaryLabelColor,
        alignment: .center,
        selectable: false
    )
    private let content = DiffSelectableTextView(
        font: AgentGitTypography.code,
        textColor: AgentGitPalette.codeText
    )
    private let contentClip = NSView()
    private var kind: GitDiffLineKind?
    private var horizontalOffset: CGFloat = 0
    private var codeContentWidth: CGFloat = 0
    private var isRowSelected = false

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
        let lineNumberWidth: CGFloat = 33
        let markerWidth: CGFloat = 14
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
        if isRowSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
            fillRect.fill()
        }
        super.draw(dirtyRect)
    }

    func updateRowSelection(_ selected: Bool) {
        guard isRowSelected != selected else { return }
        isRowSelected = selected
        needsDisplay = true
    }

    func update(line: GitDiffLine?, language: GitSyntaxLanguage) {
        kind = line?.kind
        guard let line else {
            lineNumber.stringValue = ""
            marker.stringValue = ""
            content.string = ""
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
        content.setAttributedString(
            DiffLineCellView.contentText(
                for: line,
                language: language
            )
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
        case .context: AgentGitPalette.codeBackground
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

private final class DiffSelectableTextView: NSTextView {
    /// AppKit 把点击直接派给命中的这个文本视图，表格的 mouseDown 根本不会跑，
    /// 所以跨行选择只能从这里交回给表格统一处理。
    var mouseDownHandler: ((DiffSelectableTextView, NSEvent) -> Bool)?
    var contextMenuHandler: ((DiffSelectableTextView, NSEvent) -> NSMenu?)?

    private var highlightRange = NSRange(location: 0, length: 0)

    init(font: NSFont, textColor: NSColor) {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            containerSize: NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: 18
            )
        )
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        super.init(frame: .zero, textContainer: textContainer)
        self.font = font
        self.textColor = textColor
        isEditable = false
        isSelectable = true
        isRichText = true
        importsGraphics = false
        drawsBackground = false
        focusRingType = .none
        textContainerInset = NSSize(width: 0, height: 1)
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = 1
        textContainer.lineBreakMode = .byClipping
        textContainer.widthTracksTextView = false
        textContainer.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: 18
        )
        isHorizontallyResizable = true
        isVerticallyResizable = false
        selectedTextAttributes = [
            .backgroundColor: NSColor.selectedTextBackgroundColor,
            .foregroundColor: NSColor.selectedTextColor
        ]
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
    }

    required init?(coder: NSCoder) {
        nil
    }

    var textLength: Int {
        textStorage?.length ?? 0
    }

    func setAttributedString(_ value: NSAttributedString) {
        guard textStorage?.isEqual(to: value) != true else {
            return
        }
        textStorage?.setAttributedString(value)
        setSelectedRange(NSRange(location: 0, length: 0))
        highlightRange = NSRange(location: 0, length: 0)
        needsDisplay = true
    }

    /// 选区由表格统一维护：每行只按下发的区间画底色，自己不再处理鼠标。
    func setHighlightRange(_ range: NSRange) {
        let limit = textLength
        let location = min(max(0, range.location), limit)
        let clamped = NSRange(
            location: location,
            length: min(max(0, range.length), limit - location)
        )
        guard clamped != highlightRange else {
            return
        }
        highlightRange = clamped
        needsDisplay = true
    }

    func characterIndex(forWindowPoint point: NSPoint) -> Int {
        let local = convert(point, from: nil)
        return characterIndexForInsertion(
            at: NSPoint(x: local.x, y: bounds.midY)
        )
    }

    func wordRange(at index: Int) -> NSRange {
        let limit = textLength
        guard limit > 0 else {
            return NSRange(location: 0, length: 0)
        }
        return selectionRange(
            forProposedRange: NSRange(
                location: min(max(0, index), limit - 1),
                length: 0
            ),
            granularity: .selectByWord
        )
    }

    override func mouseDown(with event: NSEvent) {
        guard mouseDownHandler?(self, event) != true else {
            return
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuHandler?(self, event) ?? super.menu(for: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawHighlight()
        super.draw(dirtyRect)
    }

    /// 选中底色铺满整行高，跨行选区在行与行之间才不会断成一节一节。
    private func drawHighlight() {
        guard highlightRange.length > 0,
              let layoutManager,
              let textContainer else {
            return
        }
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: highlightRange,
            actualCharacterRange: nil
        )
        AgentGitPalette.codeSelection.setFill()
        layoutManager.enumerateEnclosingRects(
            forGlyphRange: glyphRange,
            withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
            in: textContainer
        ) { [bounds, textContainerInset] rect, _ in
            NSRect(
                x: rect.minX + textContainerInset.width,
                y: 0,
                width: rect.width,
                height: bounds.height
            ).fill()
        }
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
            font: AgentGitTypography.code,
            textColor: AgentGitPalette.codeLineNumber,
            alignment: .right,
            selectable: false
        )
    }
}
