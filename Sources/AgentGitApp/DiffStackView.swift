import AgentGitCore
import AppKit
import CoreText
import QuartzCore
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
    case openWithApplication(UUID, lineNumber: Int? = nil)
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
        } else if firstHunk.newStart > 1 {
            // 第一个 hunk 之前的未改动行也算一段折叠上下文，和 hunk 之间的一样从下往上展开。
            let gapID = "\(fileID):context:start->\(firstHunk.id)"
            let totalLineCount = firstHunk.newStart - 1
            let requestedLineCount = min(totalLineCount, revealedLineCountByGapID[gapID] ?? 0)
            let revealedLines = contextLines(
                in: sourceLines,
                from: firstHunk.newStart - requestedLineCount,
                to: firstHunk.newStart
            )
            gaps.append(
                DiffStackContextGap(
                    id: gapID,
                    hiddenLineCount: totalLineCount - revealedLines.count,
                    revealedLines: revealedLines,
                    nextHunkAnchorID: hunkAnchorID(fileID: fileID, hunkID: firstHunk.id),
                    contextRenderID: contextRenderID
                )
            )
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
                    Image(systemName: "chevron.right")
                        .font(.agentGitInterface(size: 9, weight: .semibold))
                        .frame(width: 10, height: 10)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    StableButtonTitle(
                        title: isExpanded ? "Collapse All" : "Expand All",
                        alternatives: ["Collapse All", "Expand All"]
                    )
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
        .font(.agentGitInterface(size: 12, weight: .regular))
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
                .font(.agentGitInterface(size: 13, weight: .semibold))
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
                    .font(.agentGitInterface(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Review settings")
            .accessibilityLabel("Review settings")
        }
        .font(.agentGitInterface(size: 11).monospacedDigit())
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

struct DiffHunkPosition: Equatable, Sendable {
    let index: Int
    let count: Int
    static let empty = DiffHunkPosition(index: 0, count: 0)
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
    var fileOpenWithEntries: [WorktreeOpenWithEntry] = []
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
    var onAllChangesAction: ((GitAllChangesAction) -> Void)? = nil
    var onHunkPositionChanged: ((DiffHunkPosition) -> Void)? = nil
    /// 参数是视口顶部所在的文件，以及滚动是否已经停下。
    var onVisibleFileChanged: ((String, Bool) -> Void)? = nil
    var selectionActions: [DiffSelectionAction] = []
    /// 参数依次是操作 ID、选中的目标（没有可选目标时为 nil）和选区。
    var onSelectionContextAction: ((String, String?, DiffSelectionExcerpt) -> Void)? = nil

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
        scrollView.fileOpenWithEntries = fileOpenWithEntries
        scrollView.onFileAction = onFileAction
        scrollView.onSelectionAction = onSelectionAction
        scrollView.onAllChangesAction = onAllChangesAction
        scrollView.onHunkPositionChanged = onHunkPositionChanged
        scrollView.onVisibleFileChanged = onVisibleFileChanged
        scrollView.onSelectionContextAction = onSelectionContextAction
        scrollView.selectionActions = selectionActions
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

@MainActor
private final class DiffFlingDisplayLinkProxy: NSObject {
    weak var scrollView: DiffStackScrollView?

    init(scrollView: DiffStackScrollView) {
        self.scrollView = scrollView
    }

    @objc func handleDisplayLink(_ link: CADisplayLink) {
        guard let scrollView else {
            link.invalidate()
            return
        }
        scrollView.handleFlingDisplayLink(link)
    }
}

/// 吸顶查找只按行号定位分组和文件段，位置再向表格要。
private protocol DiffStickySection {
    var headerRow: Int { get }
}

final class DiffStackScrollView: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    private enum Metrics {
        static let lineHeight: CGFloat = 20
        static let hunkHeight = ReviewWorkspaceStyle.hunkHeaderHeight
        static let imageHeight: CGFloat = 360
        static let contextEdgeHeight = DiffHunkCellView.gapHeight
        static let fileContextToggleHeight: CGFloat = 22
        static let fileFooterHeight: CGFloat = 30
        static let fileHeight = ReviewWorkspaceStyle.fileHeaderHeight
        static let folderHeight: CGFloat = 24
        static let groupHeight: CGFloat = 32
        static let noteHeight: CGFloat = 30
        static let viewportAnchorBottomPadding: CGFloat = groupHeight + fileHeight
        static let unifiedCodeLeading = DiffLineCellView.codeLeading
        static let unifiedCodeTrailing: CGFloat = 8
        static let sideCodeLeading = DiffSideBySideCellView.sideCodeLeading
        static let sideCodeTrailing: CGFloat = 8
        static let maximumDisplayedColumns = 4_000
        @MainActor static let codeCharacterWidth = ("M" as NSString).size(
            withAttributes: [
                .font: AgentGitTypography.code
            ]
        ).width
    }

    private struct FileSection: DiffStickySection {
        let groupID: String
        let headerRow: Int
        let endRow: Int
        let file: DiffStackFile
    }

    private struct GroupSection: DiffStickySection {
        let headerRow: Int
        let endRow: Int
        let group: DiffStackGroup
    }

    var onToggleFile: ((String) -> Void)?
    var onHunkPositionChanged: ((DiffHunkPosition) -> Void)?
    var onVisibleFileChanged: ((String, Bool) -> Void)?
    /// 程序跳到某个文件后一直报这个文件，直到用户自己滚动。跳到列表末尾时文件标题到不了顶部，
    /// 按顶部位置算会报成上一个文件。
    private var pinnedVisibleFileID: String?
    private var computedVisibleFileID: String?
    private var reportedVisibleFileID: String?
    private var reportedVisibleFileIsSettled = true
    private var reportedHunkPosition: DiffHunkPosition?
    var onFocusFile: ((String) -> Void)?
    var onToggleGroup: ((String) -> Void)?
    var onToggleFolder: ((String) -> Void)?
    var onSetAllFilesExpanded: ((Bool) -> Void)?
    var onToggleReviewed: ((String) -> Void)?
    var onToggleWholeFile: ((String) -> Void)?
    var onShowHunkHistory: ((String, Int, Int) -> Void)?
    var onExpandContext: ((String, String) -> Void)?
    var onFileUtilityAction: ((String, DiffStackFileUtilityAction) -> Void)?
    var fileOpenWithEntries: [WorktreeOpenWithEntry] = []
    var onFileAction: ((String, GitPendingSelectionAction) -> Void)?
    var onSelectionAction: ((String, Set<GitDiffLine.ID>, GitPendingSelectionAction) -> Void)?
    var onSelectionContextAction: ((String, String?, DiffSelectionExcerpt) -> Void)?
    var selectionActions: [DiffSelectionAction] = [] {
        didSet {
            guard selectionActions != oldValue else {
                return
            }
            selectionActionBar.update(actions: selectionActions)
            refreshSelectionActionBar()
        }
    }
    var onAllChangesAction: ((GitAllChangesAction) -> Void)? {
        didSet {
            if (oldValue == nil) != (onAllChangesAction == nil) {
                updateVisibleMutationAvailability()
            }
        }
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
    private var isAppKitLiveScrolling = false
    private(set) var isFlingSubstepping = false
    fileprivate var isLiveScrolling: Bool {
        isAppKitLiveScrolling || isFlingSubstepping
    }
    private var flingDisplayLink: CADisplayLink?
    private var flingDisplayLinkProxy: DiffFlingDisplayLinkProxy?
    private(set) var appliedFlingDisplayLinkMaxFPS = 0
    private var pendingVerticalFlingDelta: CGFloat = 0
    private var smoothedVerticalFlingVelocity: CGFloat = 0
    private var estimatedWheelPacketInterval: CFTimeInterval = 0.033
    private var lastWheelInputTimestamp: CFTimeInterval = 0
    private var lastDistinctWheelPacketTimestamp: CFTimeInterval = 0
    private var lastFlingSubstepTimestamp: CFTimeInterval = 0
    private var lastScrollerReflectTimestamp: CFTimeInterval = 0
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
    private var rowSelectionIncludesCode = true
    private let selectionActionBar = DiffSelectionActionBar()
    private var selectionActionAnchor: SelectionActionAnchor?
    /// 拖选过程中不显示操作条，松开鼠标后再按最终选区出现。
    private var isTrackingCodeSelection = false

    /// 操作条贴着的选区：首末行和所在代码列，`.unified` 表示整行。
    private struct SelectionActionAnchor {
        let firstRow: Int
        let lastRow: Int
        let column: DiffCodeColumn
    }

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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            teardownFlingDisplayLink()
        } else {
            ensureFlingDisplayLink(screenMaxFPS: currentScreenMaxFPS)
        }
    }

    override func layout() {
        super.layout()
        updateColumnWidth()
        updateDocumentHeight()
        updateStickyHeader()
        positionSelectionActionBar()
    }

    fileprivate func moveFocusToReviewContent() {
        window?.makeFirstResponder(tableView)
    }

    fileprivate func moveControlFocus(from source: NSView, backwards: Bool) -> Bool {
        var controls: [(view: ReviewControlButton, rect: NSRect)] = []
        let stickyRect = stickyClip.isHidden ? NSRect.zero : convert(stickyClip.bounds, from: stickyClip)
        func collect(in view: NSView) {
            guard !view.isHidden else { return }
            if let button = view as? ReviewControlButton, button.canBecomeKeyView {
                let rect = convert(button.bounds, from: button)
                let center = NSPoint(x: rect.midX, y: rect.midY)
                if button.isDescendant(of: stickyClip) || !stickyRect.contains(center) {
                    controls.append((button, rect))
                }
            }
            for child in view.subviews { collect(in: child) }
        }
        collect(in: self)
        controls.sort {
            let lhsY = isFlipped ? $0.rect.midY : -$0.rect.midY
            let rhsY = isFlipped ? $1.rect.midY : -$1.rect.midY
            return abs(lhsY - rhsY) > 1 ? lhsY < rhsY : $0.rect.minX < $1.rect.minX
        }
        let nextIndex: Int
        if let current = controls.firstIndex(where: { $0.view === source }) {
            nextIndex = current + (backwards ? -1 : 1)
        } else {
            nextIndex = backwards ? controls.count - 1 : 0
        }
        guard controls.indices.contains(nextIndex), let window else { return false }
        return window.makeFirstResponder(controls[nextIndex].view)
    }

    private var currentScreenMaxFPS: Int {
        window?.screen?.maximumFramesPerSecond
            ?? NSScreen.main?.maximumFramesPerSecond
            ?? 120
    }

    override func scrollWheel(with event: NSEvent) {
        pinnedVisibleFileID = nil
        if !Self.shouldForwardScrollWheel(
            horizontalDelta: event.scrollingDeltaX,
            verticalDelta: event.scrollingDeltaY
        ) {
            cancelFlingSubstepping()
            let tablePoint = tableView.convert(event.locationInWindow, from: nil)
            _ = scrollCodeHorizontally(
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
        let stepDeltaY = Self.verticalScrollPointDelta(for: event)
        let handledBySubstepper = receiveVerticalScrollInput(
            stepDeltaY: stepDeltaY,
            phase: event.phase,
            momentumPhase: event.momentumPhase,
            now: CACurrentMediaTime(),
            screenMaxFPS: currentScreenMaxFPS
        )
        if !handledBySubstepper {
            super.scrollWheel(with: event)
        }
    }

    static func verticalScrollPointDelta(for event: NSEvent) -> CGFloat {
        if event.hasPreciseScrollingDeltas {
            return -event.scrollingDeltaY
        }
        return -event.scrollingDeltaY * Metrics.lineHeight
    }

    func ensureFlingDisplayLink(screenMaxFPS: Int) {
        let targetHz = max(60, screenMaxFPS)
        if flingDisplayLink == nil {
            let proxy = flingDisplayLinkProxy ?? DiffFlingDisplayLinkProxy(scrollView: self)
            flingDisplayLinkProxy = proxy
            let link = displayLink(
                target: proxy,
                selector: #selector(DiffFlingDisplayLinkProxy.handleDisplayLink(_:))
            )
            link.isPaused = !isFlingSubstepping
            link.add(to: .main, forMode: .common)
            flingDisplayLink = link
            appliedFlingDisplayLinkMaxFPS = 0
        }
        guard let link = flingDisplayLink, appliedFlingDisplayLinkMaxFPS != targetHz else {
            return
        }
        appliedFlingDisplayLinkMaxFPS = targetHz
        let maxRate = Float(targetHz)
        let minRate = min(Float(80), maxRate)
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: minRate,
            maximum: maxRate,
            preferred: maxRate
        )
    }

    private func teardownFlingDisplayLink() {
        cancelFlingSubstepping()
        flingDisplayLink?.invalidate()
        flingDisplayLink = nil
        appliedFlingDisplayLinkMaxFPS = 0
    }

    @discardableResult
    func receiveVerticalScrollInput(
        stepDeltaY: CGFloat,
        phase: NSEvent.Phase,
        momentumPhase: NSEvent.Phase,
        now: CFTimeInterval,
        screenMaxFPS: Int
    ) -> Bool {
        // 触控板与 Magic Mouse 自带 phase / momentumPhase，直接走 AppKit 原生高刷滚动与惯性曲线。
        if phase != [] || momentumPhase != [] {
            cancelFlingSubstepping()
            lastWheelInputTimestamp = now
            lastDistinctWheelPacketTimestamp = now
            return false
        }

        guard abs(stepDeltaY) >= 0.01 else {
            return isFlingSubstepping
        }

        let rawDt = lastWheelInputTimestamp > 0 ? max(0, now - lastWheelInputTimestamp) : 1.0
        lastWheelInputTimestamp = now

        // 慢速单格刻度保持 1:1 立即跳变，不加拖尾平滑；连续快速甩动则进入高刷 vsync 步进。
        if !isFlingSubstepping, abs(stepDeltaY) <= 28, rawDt > 0.075 {
            lastDistinctWheelPacketTimestamp = now
            return false
        }

        enqueueFlingVerticalDelta(stepDeltaY, now: now, screenMaxFPS: screenMaxFPS)
        return true
    }

    private func enqueueFlingVerticalDelta(
        _ stepDeltaY: CGFloat,
        now: CFTimeInterval,
        screenMaxFPS: Int
    ) {
        if pendingVerticalFlingDelta * stepDeltaY < 0 {
            pendingVerticalFlingDelta = 0
            smoothedVerticalFlingVelocity = 0
        }

        if lastDistinctWheelPacketTimestamp > 0 {
            let gap = now - lastDistinctWheelPacketTimestamp
            if gap >= 0.008 {
                if gap <= 0.16 {
                    let clampedGap = min(max(gap, 0.012), 0.095)
                    let weight = clampedGap > estimatedWheelPacketInterval ? 0.65 : 0.20
                    estimatedWheelPacketInterval += (clampedGap - estimatedWheelPacketInterval) * weight
                } else {
                    estimatedWheelPacketInterval = 0.033
                }
                lastDistinctWheelPacketTimestamp = now
            }
        } else {
            lastDistinctWheelPacketTimestamp = now
        }

        pendingVerticalFlingDelta += stepDeltaY

        let wasLive = isLiveScrolling
        let wasSubstepping = isFlingSubstepping
        isFlingSubstepping = true
        if !wasLive {
            noteLiveScrollStateTransition(wasLiveScrolling: false)
        }
        ensureFlingDisplayLink(screenMaxFPS: screenMaxFPS)
        flingDisplayLink?.isPaused = false

        if !wasSubstepping {
            if !isAppKitLiveScrolling {
                flashScrollers()
            }
            let nominalDt = 1.0 / Double(max(60, screenMaxFPS))
            lastFlingSubstepTimestamp = now - nominalDt
            _ = stepFlingSubstepper(at: now, nominalFrameDuration: nominalDt)
        }
    }

    fileprivate func handleFlingDisplayLink(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let linkInterval = link.targetTimestamp - link.timestamp
        let nominalDt = linkInterval > 0.002
            ? linkInterval
            : (1.0 / Double(max(60, currentScreenMaxFPS)))
        _ = stepFlingSubstepper(at: now, nominalFrameDuration: nominalDt)
    }

    @discardableResult
    func stepFlingSubstepper(
        at now: CFTimeInterval,
        nominalFrameDuration: CFTimeInterval
    ) -> CGFloat {
        guard isFlingSubstepping else {
            flingDisplayLink?.isPaused = true
            return 0
        }

        let rawDt = lastFlingSubstepTimestamp > 0 ? (now - lastFlingSubstepTimestamp) : nominalFrameDuration
        guard rawDt >= 0.0028 else {
            return 0
        }
        lastFlingSubstepTimestamp = now
        let dt = CGFloat(min(max(rawDt, 1.0 / 240.0), 1.0 / 30.0))

        let remaining = pendingVerticalFlingDelta
        let idleSinceInput = lastWheelInputTimestamp > 0 ? max(0, now - lastWheelInputTimestamp) : 0
        let tailThreshold = max(0.075, estimatedWheelPacketInterval * 2.0)

        if abs(remaining) < 0.20 {
            var applied: CGFloat = 0
            if abs(remaining) > 0.001 {
                applied = applyVerticalScrollStep(remaining, now: now)
            }
            pendingVerticalFlingDelta = 0
            smoothedVerticalFlingVelocity = 0
            if idleSinceInput >= tailThreshold {
                finishFlingSubstepping()
            }
            return applied
        }

        var horizon = min(max(estimatedWheelPacketInterval * 2.05, 0.048), 0.140)
        let isDrainingTail = idleSinceInput > tailThreshold
        if isDrainingTail {
            let tailProgress = min(1.0, (idleSinceInput - tailThreshold) / 0.12)
            horizon = max(0.028, horizon * (1.0 - 0.55 * tailProgress))
        }

        let desiredVelocity = remaining / CGFloat(horizon)
        if abs(smoothedVerticalFlingVelocity) < 1 {
            smoothedVerticalFlingVelocity = desiredVelocity
        } else {
            let alpha: CGFloat = abs(desiredVelocity) > abs(smoothedVerticalFlingVelocity) ? 0.45 : 0.25
            smoothedVerticalFlingVelocity += (desiredVelocity - smoothedVerticalFlingVelocity) * alpha
        }

        var step = smoothedVerticalFlingVelocity * dt
        let minStep: CGFloat = isDrainingTail ? 0.55 : 0.25
        if abs(step) < minStep {
            step = remaining > 0 ? minStep : -minStep
        }
        if abs(step) > abs(remaining) {
            step = remaining
        }

        pendingVerticalFlingDelta -= step
        let applied = applyVerticalScrollStep(step, now: now)
        if abs(applied) < abs(step) - 0.01 {
            pendingVerticalFlingDelta = 0
            smoothedVerticalFlingVelocity = 0
            finishFlingSubstepping()
        }
        return applied
    }

    @discardableResult
    private func applyVerticalScrollStep(_ deltaY: CGFloat, now: CFTimeInterval = 0) -> CGFloat {
        let maxOffset = max(0, tableView.bounds.height - contentView.bounds.height)
        let currentY = contentView.bounds.minY
        let nextY = min(max(0, currentY + deltaY), maxOffset)
        let applied = nextY - currentY
        guard abs(applied) > 0.0005 else {
            return 0
        }
        contentView.scroll(to: NSPoint(x: 0, y: nextY))
        if !isFlingSubstepping || now <= 0 || now - lastScrollerReflectTimestamp >= 0.016 {
            if now > 0 {
                lastScrollerReflectTimestamp = now
            }
            reflectScrolledClipView(contentView)
        }
        return applied
    }

    func cancelFlingSubstepping() {
        pendingVerticalFlingDelta = 0
        smoothedVerticalFlingVelocity = 0
        lastFlingSubstepTimestamp = 0
        if isFlingSubstepping {
            finishFlingSubstepping()
        } else {
            flingDisplayLink?.isPaused = true
        }
    }

    private func finishFlingSubstepping() {
        let wasLive = isLiveScrolling
        isFlingSubstepping = false
        lastFlingSubstepTimestamp = 0
        lastScrollerReflectTimestamp = 0
        flingDisplayLink?.isPaused = true
        reflectScrolledClipView(contentView)
        noteLiveScrollStateTransition(wasLiveScrolling: wasLive)
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
        cancelFlingSubstepping()
        if let previousKey = scrollKey, pendingRestoreOffset == nil {
            store.saveScrollOffset(contentView.bounds.minY, for: previousKey)
        }
        scrollKey = key
        reportedHunkPosition = nil
        pinnedVisibleFileID = nil
        computedVisibleFileID = nil
        reportedVisibleFileID = nil
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
            cancelFlingSubstepping()
            pendingRestoreOffset = nil
            pendingCodeAnchor = nil
            pendingHunkAnchor = nil
            scroll(toFileID: fileID)
        case let .requestFileDiscard(fileID):
            cancelFlingSubstepping()
            _ = requestFileDiscard(fileID: fileID)
        case let .moveHunk(offset):
            cancelFlingSubstepping()
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
        cancelFlingSubstepping()
        contentView.scroll(to: NSPoint(x: 0, y: target))
        reflectScrolledClipView(contentView)
        pendingRestoreOffset = nil
        updateStickyHeader()
    }

    private func restoreVerticalOffset(_ offset: CGFloat) {
        cancelFlingSubstepping()
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
            let expansionChanged = previousToken.map { token.expansionChanged(from: $0) } ?? false
            let hadPendingAnchor = pendingCodeAnchor != nil
                || pendingHunkAnchor != nil
            if !hadPendingAnchor {
                anchorMinimumDocumentHeight = nil
            }
            let automaticAnchor: PendingCodeAnchor? = if !hadPendingAnchor,
                                                         pendingRestoreOffset == nil,
                                                         !expansionChanged {
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
        refreshSelectionActionBar()

        guard scrollTarget != appliedScrollTarget else {
            return
        }
        appliedScrollTarget = scrollTarget
        if let scrollTarget, pendingRestoreOffset == nil {
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
                historyHandler: { [weak self] fileID, startLine, endLine in
                    self?.focusFile(fileID)
                    self?.onShowHunkHistory?(fileID, startLine, endLine)
                },
                actionHandler: { [weak self] fileID, lineIDs, action in
                    self?.focusFile(fileID)
                    self?.onSelectionAction?(fileID, lineIDs, action)
                }
            )
            cell.updateRowSelection(tableView.selectedRowIndexes.contains(row))
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
        case let .fileFooter(fileID):
            let cell = reusableCell(DiffFileFooterCellView.self, identifier: DiffFileFooterCellView.identifier)
            cell.update(fileID: fileID) { [weak self] fileID in
                self?.handleFooterCollapse(fileID: fileID)
            }
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
        rowSelectionIncludesCode = true
        publishHunkPosition()
        refreshSelectionActionBar()
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
        return rowHeight(for: rows[row])
    }

    private func rowHeight(for row: DiffStackRow) -> CGFloat {
        switch row {
        case .summary: summaryRowHeight
        case .group: Metrics.groupHeight
        case .folder: Metrics.folderHeight
        case .file: Metrics.fileHeight
        case let .hunk(hunk): hunk.contextGap == nil ? Metrics.hunkHeight : DiffHunkCellView.gapHeight
        case .contextEdge: Metrics.contextEdgeHeight
        case .fileContextToggle: Metrics.fileContextToggleHeight
        case .fileFooter: Metrics.fileFooterHeight
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
        case .summary, .group, .folder, .file, .fileContextToggle, .fileFooter, .contextEdge,
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
                    case .summary, .group, .folder, .file, .fileContextToggle, .fileFooter,
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
        defer { rows.append(.fileFooter(fileID: file.id)) }
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
            case .summary, .group, .folder, .file, .fileContextToggle, .fileFooter, .hunk,
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
        cancelFlingSubstepping()
        pinnedVisibleFileID = fileID
        reportedVisibleFileID = fileID
        reportedVisibleFileIsSettled = true
        tableView.layoutSubtreeIfNeeded()
        let rect = tableView.rect(ofRow: row)
        let groupHeight = stickyGroupHeight(for: fileSectionIndexByID[fileID].map { fileSections[$0] })
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
        case .summary, .group, .folder, .file, .fileContextToggle, .fileFooter, .hunk,
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
        case .summary, .group, .folder, .file, .fileContextToggle, .fileFooter, .hunk,
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
        cancelFlingSubstepping()
        pinnedVisibleFileID = nil
        // 与顶栏显示的当前 hunk 一致，手动滚动后不再沿用屏幕外的旧选中行。
        let activePosition = isLiveScrolling ? currentHunkPosition() : reportedHunkPosition
        let currentIndex = activePosition.flatMap { $0.count > 0 ? $0.index - 1 : nil }
            ?? (offset > 0 ? -1 : 0)
        let count = hunkRowIndexes.count
        let targetIndex = (currentIndex + offset % count + count) % count
        let targetRow = hunkRowIndexes[targetIndex]

        tableView.selectRowIndexes(
            IndexSet(integer: targetRow),
            byExtendingSelection: false
        )
        let targetMinY = tableRowMinY(targetRow)
        // 按目标所在文件实际会出现的吸顶高度留位置。多留了没有的分组标题高度时，
        // 跳到下一个文件的第一个 hunk 会让上一个文件的吸顶标题停在新文件标题上方。
        let stickyHeight = stickyGroupHeight(for: fileSection(containingRow: targetRow))
            + Metrics.fileHeight
        let targetOffset = max(0, targetMinY - stickyHeight)
        let maxOffset = max(0, tableView.bounds.height - contentView.bounds.height)
        contentView.scroll(
            to: NSPoint(x: 0, y: min(targetOffset, maxOffset))
        )
        reflectScrolledClipView(contentView)
        updateStickyHeader()
        publishHunkPosition()
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
        tableView.dynamicMenuProvider = { [weak self] row, selectedRows, hadSelection in
            self?.contextMenu(clickedRow: row, selectedRows: selectedRows, includesSelectedCode: hadSelection)
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
        configureGroupActions(stickyGroupHeader)
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
        selectionActionBar.isHidden = true
        selectionActionBar.actionHandler = { [weak self] action, button in
            self?.runSelectionAction(action, from: button)
        }
        addSubview(selectionActionBar, positioned: .above, relativeTo: stickyClip)

        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewBoundsChanged),
            name: NSView.boundsDidChangeNotification,
            object: contentView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewWillStartLiveScroll),
            name: NSScrollView.willStartLiveScrollNotification,
            object: self
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidEndLiveScroll),
            name: NSScrollView.didEndLiveScrollNotification,
            object: self
        )
    }

    @objc private func scrollViewWillStartLiveScroll() {
        pinnedVisibleFileID = nil
        let wasLive = isLiveScrolling
        isAppKitLiveScrolling = true
        noteLiveScrollStateTransition(wasLiveScrolling: wasLive)
    }

    @objc private func scrollViewDidEndLiveScroll() {
        let wasLive = isLiveScrolling
        isAppKitLiveScrolling = false
        noteLiveScrollStateTransition(wasLiveScrolling: wasLive)
    }

    private func noteLiveScrollStateTransition(wasLiveScrolling: Bool) {
        let nowLive = isLiveScrolling
        guard nowLive != wasLiveScrolling else {
            return
        }
        if nowLive {
            tableView.clearPointerHover()
            return
        }
        if let window {
            tableView.refreshPointerHover(windowPoint: window.mouseLocationOutsideOfEventStream)
        }
        if isApplicationActive,
           !isApplyingPresentationUpdate,
           pendingRestoreOffset == nil,
           let scrollKey {
            scrollStore?.saveScrollOffset(contentView.bounds.minY, for: scrollKey)
        }
        publishHunkPosition()
        publishVisibleFile()
    }

    /// 顶部文件变了就报，滚动停下时再报一次已停下，焦点等停下再改，免得重绘打断滚动惯性。
    private func publishVisibleFile() {
        guard let fileID = pinnedVisibleFileID ?? computedVisibleFileID else {
            return
        }
        let isSettled = !isLiveScrolling
        guard fileID != reportedVisibleFileID
                || (isSettled && !reportedVisibleFileIsSettled) else {
            return
        }
        reportedVisibleFileID = fileID
        reportedVisibleFileIsSettled = isSettled
        let key = scrollKey
        DispatchQueue.main.async { [weak self] in
            guard let self, self.scrollKey == key, self.reportedVisibleFileID == fileID else { return }
            self.onVisibleFileChanged?(fileID, isSettled)
        }
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
        let currentOrigin = contentView.bounds.origin
        let isUserScroll = isApplicationActive
            && !isApplyingPresentationUpdate
            && pendingRestoreOffset == nil

        if isUserScroll, let scrollKey {
            if isLiveScrolling {
                scrollStore?.recordScrollOffsetInMemory(currentOrigin.y, for: scrollKey)
            } else {
                scrollStore?.saveScrollOffset(currentOrigin.y, for: scrollKey)
            }
        }
        updateStickyHeader()
        positionSelectionActionBar()
    }

    /// NSScrollView 跟随 document view 翻转，这里 minY 就是视口顶边。
    private func updateStickyHeader() {
        guard !isUpdatingSticky else {
            return
        }
        isUpdatingSticky = true
        defer {
            isUpdatingSticky = false
            if !isLiveScrolling {
                publishHunkPosition()
            }
        }

        let top = contentView.bounds.minY
        let groupSection = lastSection(in: groupSections, atOrBeforeRow: tableRowIndex(atY: top))
        let groupVisibleHeight = stickyGroupVisibleHeight(
            for: groupSection,
            top: top
        )
        let fileTop = top + groupVisibleHeight
        let fileTopRow = tableRowIndex(atY: fileTop)
        if let visibleFileID = self.fileSection(containingRow: fileTopRow)?.file.id {
            computedVisibleFileID = visibleFileID
        }
        publishVisibleFile()
        var fileSection = lastSection(in: fileSections, atOrBeforeRow: fileTopRow)
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
                configureGroupActions(stickyGroupHeader)
            }
            if stickyGroupHeader.isHidden {
                stickyGroupHeader.isHidden = false
            }
        } else {
            stickyGroupID = nil
            if !stickyGroupHeader.isHidden {
                stickyGroupHeader.isHidden = true
            }
        }

        if fileVisibleHeight > 1, let fileSection {
            if stickyFileID != fileSection.file.id {
                stickyFileID = fileSection.file.id
                stickyFileHeader.update(
                    file: fileSection.file,
                    mutationActionsEnabled: mutationActionsEnabled
                )
            }
            if stickyFileHeader.isHidden {
                stickyFileHeader.isHidden = false
            }
        } else {
            stickyFileID = nil
            if !stickyFileHeader.isHidden {
                stickyFileHeader.isHidden = true
            }
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
        if stickyClip.isHidden {
            stickyClip.isHidden = false
        }
    }

    private func hideStickyHeaders() {
        guard !stickyClip.isHidden || stickyGroupID != nil || stickyFileID != nil else {
            return
        }
        stickyGroupID = nil
        stickyFileID = nil
        stickyGroupHeader.isHidden = true
        stickyFileHeader.isHidden = true
        stickyClip.isHidden = true
    }

    private func currentHunkPosition() -> DiffHunkPosition {
        guard !hunkRowIndexes.isEmpty else {
            return .empty
        }
        let viewportBounds = contentView.bounds
        let selectedRow = tableView.selectedRow
        let selectedIsVisible: Bool = if selectedRow >= 0 && selectedRow < tableView.numberOfRows {
            tableView.rect(ofRow: selectedRow).maxY > viewportBounds.minY
                && tableView.rect(ofRow: selectedRow).minY < viewportBounds.maxY
        } else {
            false
        }
        let visibleTop = viewportBounds.minY + (stickyClip.isHidden ? 0 : stickyClip.bounds.height) + 1
        let anchorRow = selectedIsVisible ? selectedRow : tableRowIndex(atY: visibleTop)
        var low = 0
        var high = hunkRowIndexes.count
        while low < high {
            let mid = (low + high) / 2
            if hunkRowIndexes[mid] <= anchorRow { low = mid + 1 }
            else { high = mid }
        }
        return DiffHunkPosition(index: max(1, low), count: hunkRowIndexes.count)
    }

    private func publishHunkPosition() {
        let position = currentHunkPosition()
        guard position != reportedHunkPosition else { return }
        reportedHunkPosition = position
        let key = scrollKey
        // 等 AppKit 完成本次布局后再更新 SwiftUI 顶栏。
        DispatchQueue.main.async { [weak self] in
            guard let self, self.scrollKey == key, self.reportedHunkPosition == position else { return }
            self.onHunkPositionChanged?(position)
        }
    }

    /// 行位置一律向表格要。行数很多时 AppKit 对还没排到的行先按估算位置摆放，
    /// 自己按行高累加的位置会和屏幕上画出来的行对不上，吸顶标题就会选错文件、推开时机不对。
    /// 低于最后一行（底部留白）时按最后一行算，空表或视口在内容上方时返回 -1。
    private func tableRowIndex(atY y: CGFloat) -> Int {
        let count = tableView.numberOfRows
        guard count > 0, count == rows.count, y >= 0 else {
            return -1
        }
        let row = tableView.row(at: NSPoint(x: tableView.bounds.midX, y: y))
        if row >= 0 {
            return row
        }
        return y >= tableView.rect(ofRow: count - 1).maxY ? count - 1 : -1
    }

    /// 行的顶边；超出最后一行时用表格底边，和最后一段一直延伸到底部留白一致。
    private func tableRowMinY(_ row: Int) -> CGFloat {
        row < tableView.numberOfRows ? tableView.rect(ofRow: row).minY : tableView.bounds.maxY
    }

    /// 标题行不晚于 row 的最后一段。
    private func lastSection<Section: DiffStickySection>(
        in sections: [Section],
        atOrBeforeRow row: Int
    ) -> Section? {
        guard row >= 0 else {
            return nil
        }
        var low = 0
        var high = sections.count - 1
        var found: Section?
        while low <= high {
            let mid = (low + high) / 2
            if sections[mid].headerRow <= row {
                found = sections[mid]
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }

    /// 文件所在分组有标题行时，滚动定位要给吸顶分组标题留出高度；没有标题的分组（如 commit）不留。
    private func stickyGroupHeight(for section: FileSection?) -> CGFloat {
        guard let section,
              groupSections.contains(where: { $0.group.id == section.groupID }) else {
            return 0
        }
        return Metrics.groupHeight
    }

    private func stickyGroupVisibleHeight(
        for section: GroupSection?,
        top: CGFloat
    ) -> CGFloat {
        guard let section, tableRowMinY(section.headerRow) < top else {
            return 0
        }
        return max(0, min(Metrics.groupHeight, tableRowMinY(section.endRow) - top))
    }

    private func stickyFileVisibleHeight(
        for section: FileSection?,
        top: CGFloat
    ) -> CGFloat {
        guard let section,
              section.endRow > section.headerRow + 1,
              tableRowMinY(section.headerRow) < top else {
            return 0
        }
        return max(0, min(Metrics.fileHeight, tableRowMinY(section.endRow) - top))
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

    private func handleFooterCollapse(fileID: String) {
        guard let index = fileSectionIndexByID[fileID], fileSections[index].file.isExpanded else {
            return
        }
        handleStickyClick(fileID: fileID)
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
        case .summary, .hunk, .line, .sideBySide, .fileContextToggle, .fileFooter,
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

    func contextMenu(clickedRow: Int, selectedRows: IndexSet, includesSelectedCode: Bool? = nil) -> NSMenu {
        if let includesSelectedCode {
            rowSelectionIncludesCode = includesSelectedCode && rowSelectionIncludesCode
        }
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
            addCustomOpenWithItems(for: file, to: menu)
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
            addSelectionActionItems(to: menu, clickedRow: clickedRow)
            if !fileOpenWithEntries.isEmpty,
               let section = fileSection(containingRow: clickedRow) {
                if !menu.items.isEmpty {
                    menu.addItem(.separator())
                }
                addCustomOpenWithItems(
                    for: section.file,
                    lineNumber: workingLineNumber(atRow: clickedRow, file: section.file),
                    to: menu
                )
            }
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

        case .summary, .group, .folder, .fileContextToggle, .fileFooter, .contextEdge, .image,
             .note:
            break
        }
        return menu
    }

    private func addCustomOpenWithItems(
        for file: DiffStackFile,
        lineNumber: Int? = nil,
        to menu: NSMenu
    ) {
        for entry in fileOpenWithEntries {
            let applicationURL = entry.applicationURL()
            addMenuItem(
                entry.menuTitle(applicationURL: applicationURL, opensSelectedFile: true),
                command: .fileUtility(file.id, .openWithApplication(entry.id, lineNumber: lineNumber)),
                to: menu,
                isEnabled: file.canOpenWorkingFile && applicationURL != nil
            )
        }
    }

    /// 打开工作区文件时使用新行号；删除行定位到删除位置附近仍存在的行。
    private func workingLineNumber(atRow row: Int, file: DiffStackFile) -> Int? {
        guard let line = representativeLine(in: rows[row], fileID: file.id) else { return nil }
        if let lineNumber = line.newLineNumber {
            return lineNumber
        }
        guard let hunk = file.diff?.hunks.first(where: { hunk in
            hunk.lines.contains { $0.id == line.id }
        }) else { return nil }
        var nextLineNumber = max(1, hunk.newStart + (hunk.newCount == 0 ? 1 : 0))
        for candidate in hunk.lines {
            if candidate.id == line.id {
                return nextLineNumber
            }
            if let lineNumber = candidate.newLineNumber {
                nextLineNumber = lineNumber + 1
            }
        }
        return nil
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
            case .summary, .group, .folder, .file, .fileContextToggle, .fileFooter, .hunk,
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
        case .summary, .group, .folder, .file, .fileContextToggle, .fileFooter, .hunk,
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
            case .summary, .group, .folder, .file, .fileContextToggle, .fileFooter, .hunk,
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
        cell.setActions(enabled: mutationActionsEnabled && onAllChangesAction != nil) { [weak self] action in
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
        case let .fileFooter(fileID): return [.fileFooter(fileID)]
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
        isTrackingCodeSelection = true
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
        refreshSelectionActionBar()
        trackCodeSelectionDrag()
        isTrackingCodeSelection = false
        refreshSelectionActionBar()
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
            textView.contextMenuHandler = { [weak self] textView, event in
                self?.codeContextMenu(for: event, textView: textView)
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
    private func codeContextMenu(for event: NSEvent, textView: DiffSelectableTextView) -> NSMenu? {
        let row = tableView.row(
            at: tableView.convert(event.locationInWindow, from: nil)
        )
        guard rows.indices.contains(row) else {
            return nil
        }
        let hadSelection = codeSelectionRows(containing: row) != nil
            || textView.selectedRange().length > 0
            || (tableView.selectedRowIndexes.contains(row) && rowSelectionIncludesCode)
        if codeSelectionRows(containing: row) == nil {
            tableView.selectRowIndexes(
                IndexSet(integer: row),
                byExtendingSelection: false
            )
        }
        rowSelectionIncludesCode = hadSelection
        return contextMenu(clickedRow: row, selectedRows: tableView.selectedRowIndexes, includesSelectedCode: hadSelection)
    }

    private func clearCodeSelection() {
        guard codeSelection != nil else {
            return
        }
        codeSelection = nil
        applyCodeSelectionHighlights()
        refreshSelectionActionBar()
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
        case .summary, .group, .folder, .file, .fileContextToggle, .fileFooter, .hunk,
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
            case .summary, .file, .folder, .group, .fileContextToggle, .fileFooter,
                 .contextEdge, .image, .note:
                return nil
            }
        }.joined(separator: "\n")
    }

    // MARK: - 选区操作

    private struct SelectedCode {
        let fileID: String
        let rows: [Int]
        let column: DiffCodeColumn
        let lines: [GitDiffLine]
        var includesSelectedCode = true

        var excerpt: DiffSelectionExcerpt {
            DiffSelectionExcerpt(fileID: fileID, lines: lines, includesSelectedCode: includesSelectedCode)
        }
    }

    private func codeRowFileID(_ row: Int) -> String? {
        guard rows.indices.contains(row) else {
            return nil
        }
        switch rows[row] {
        case let .line(_, _, fileID, _, _), let .sideBySide(_, _, fileID, _, _):
            return fileID
        case .summary, .group, .folder, .file, .fileContextToggle, .fileFooter, .hunk,
             .contextEdge, .image, .note:
            return nil
        }
    }

    /// 当前选中的代码，只认同一个文件里的代码行。拖选优先；右键落在拖选范围外时用表格选中的行。
    private func selectedCode(clickedRow: Int? = nil) -> SelectedCode? {
        if let codeSelection, !codeSelection.isEmpty,
           clickedRow.map({ codeSelectionRows(containing: $0) != nil }) ?? true {
            return selectedCode(in: codeSelection)
        }
        return selectedCode(inRows: tableView.selectedRowIndexes)
    }

    private func selectedCode(in selection: DiffCodeSelection) -> SelectedCode? {
        let spans = selectedCodeSpans(for: selection, in: rows).sorted { $0.row < $1.row }
        var fileID: String?
        var selectedRows: [Int] = []
        var lines: [GitDiffLine] = []
        var column = selection.column
        for (index, span) in spans.enumerated() {
            // 首尾行只选到行首或行尾外侧时不算；中间的空行长度为 0，照样算。
            guard span.range.length > 0 || (index > 0 && index < spans.count - 1),
                  let line = codeLine(atRow: span.row, column: span.column),
                  let rowFileID = codeRowFileID(span.row) else {
                continue
            }
            if let fileID, fileID != rowFileID {
                return nil
            }
            fileID = rowFileID
            selectedRows.append(span.row)
            lines.append(line)
            column = span.column
        }
        guard let fileID, !lines.isEmpty else {
            return nil
        }
        return SelectedCode(fileID: fileID, rows: selectedRows, column: column, lines: lines)
    }

    private func selectedCode(inRows selectedRows: IndexSet) -> SelectedCode? {
        var fileID: String?
        var codeRows: [Int] = []
        var unifiedLines: [GitDiffLine] = []
        var pairs: [(row: Int, old: GitDiffLine?, new: GitDiffLine?)] = []
        for row in selectedRows {
            guard let rowFileID = codeRowFileID(row) else {
                continue
            }
            if let fileID, fileID != rowFileID {
                return nil
            }
            fileID = rowFileID
            codeRows.append(row)
            switch rows[row] {
            case let .line(line, _, _, _, _):
                unifiedLines.append(line)
            case let .sideBySide(pair, _, _, _, _):
                pairs.append((row, pair.old, pair.new))
            default:
                continue
            }
        }
        let lines = unifiedLines + unifiedDiffSelectionOrder(pairs)
        guard let fileID, !lines.isEmpty else {
            return nil
        }
        return SelectedCode(fileID: fileID, rows: codeRows, column: .unified, lines: lines, includesSelectedCode: rowSelectionIncludesCode)
    }

    /// 选区变了以后重新找操作条的锚点；滚动和尺寸变化只需要 `positionSelectionActionBar`。
    private func refreshSelectionActionBar() {
        if isTrackingCodeSelection || selectionActions.isEmpty {
            selectionActionAnchor = nil
        } else {
            selectionActionAnchor = selectedCode().flatMap { selected in
                guard let first = selected.rows.first, let last = selected.rows.last else {
                    return nil
                }
                return SelectionActionAnchor(firstRow: first, lastRow: last, column: selected.column)
            }
        }
        positionSelectionActionBar()
    }

    /// 操作条叠在表格上方，贴着选区最后一行的下方、靠所在代码列的右侧；下方放不下时放到首行上方，
    /// 选区比视口还高时停在视口底部。行的位置不受它影响。
    private func positionSelectionActionBar() {
        guard let anchor = selectionActionAnchor,
              rows.indices.contains(anchor.firstRow),
              rows.indices.contains(anchor.lastRow),
              anchor.lastRow < tableView.numberOfRows else {
            if !selectionActionBar.isHidden {
                selectionActionBar.isHidden = true
            }
            return
        }
        let gap: CGFloat = 4
        let size = selectionActionBar.preferredSize
        let viewport = contentView.frame
        let topLimit = stickyClip.isHidden ? viewport.minY : max(viewport.minY, stickyClip.frame.maxY)
        let selectionRect = convert(
            tableView.rect(ofRow: anchor.firstRow).union(tableView.rect(ofRow: anchor.lastRow)),
            from: tableView
        )
        guard selectionRect.maxY > topLimit, selectionRect.minY < viewport.maxY else {
            if !selectionActionBar.isHidden {
                selectionActionBar.isHidden = true
            }
            return
        }
        var y = selectionRect.maxY + gap
        if y + size.height > viewport.maxY - gap {
            let above = selectionRect.minY - gap - size.height
            y = above >= topLimit + gap ? above : viewport.maxY - gap - size.height
        }
        y = max(y, topLimit + gap)
        let cellRect = tableView.frameOfCell(atColumn: 0, row: anchor.lastRow)
        let columnMaxX = anchor.column == .old ? cellRect.midX : cellRect.maxX
        let trailing = convert(NSPoint(x: columnMaxX, y: cellRect.minY), from: tableView).x - 12
        let x = min(max(trailing - size.width, viewport.minX + 8), viewport.maxX - size.width - 8)
        let frame = NSRect(x: round(x), y: round(y), width: size.width, height: size.height)
        if selectionActionBar.frame != frame {
            selectionActionBar.frame = frame
        }
        selectionActionBar.isHidden = false
    }

    private func runSelectionAction(_ action: DiffSelectionAction, from view: NSView) {
        guard action.isEnabled, let selected = selectedCode() else {
            return
        }
        guard action.choices.count > 1 else {
            focusFile(selected.fileID)
            onSelectionContextAction?(action.id, action.choices.first?.id, selected.excerpt)
            return
        }
        let menu = NSMenu()
        addSelectionChoiceItems(for: action, excerpt: selected.excerpt, to: menu)
        let y = view.isFlipped ? view.bounds.maxY + 4 : -4
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: view)
    }

    private func addSelectionActionItems(to menu: NSMenu, clickedRow: Int) {
        guard !selectionActions.isEmpty,
              let selected = selectedCode(clickedRow: clickedRow) else {
            return
        }
        menu.addItem(.separator())
        for action in selectionActions {
            guard action.choices.count > 1 else {
                let item = selectionMenuItem(
                    title: action.title,
                    command: DiffSelectionMenuCommand(
                        actionID: action.id,
                        choiceID: action.choices.first?.id,
                        excerpt: selected.excerpt
                    )
                )
                item.isEnabled = action.isEnabled
                item.toolTip = action.help
                menu.addItem(item)
                continue
            }
            let submenu = NSMenu(title: action.title)
            addSelectionChoiceItems(for: action, excerpt: selected.excerpt, to: submenu)
            let item = NSMenuItem(title: action.title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            item.isEnabled = action.isEnabled
            item.toolTip = action.help
            menu.addItem(item)
        }
    }

    private func addSelectionChoiceItems(
        for action: DiffSelectionAction,
        excerpt: DiffSelectionExcerpt,
        to menu: NSMenu
    ) {
        for choice in action.choices {
            menu.addItem(selectionMenuItem(
                title: choice.title,
                command: DiffSelectionMenuCommand(actionID: action.id, choiceID: choice.id, excerpt: excerpt)
            ))
        }
    }

    private func selectionMenuItem(title: String, command: DiffSelectionMenuCommand) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runSelectionMenuAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = command
        return item
    }

    @objc private func runSelectionMenuAction(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? DiffSelectionMenuCommand else {
            return
        }
        focusFile(command.excerpt.fileID)
        onSelectionContextAction?(command.actionID, command.choiceID, command.excerpt)
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

    func expansionChanged(from previous: DiffStackToken) -> Bool {
        let previousFiles = Dictionary(uniqueKeysWithValues: previous.entries.map { ($0.id, $0) })
        if entries.contains(where: { entry in
            guard let old = previousFiles[entry.id] else { return false }
            return entry.isExpanded != old.isExpanded || entry.groupIsExpanded != old.groupIsExpanded
        }) {
            return true
        }
        let previousFolders = Dictionary(uniqueKeysWithValues: previous.folders.map { ($0.id, $0.isExpanded) })
        if folders.contains(where: { folder in
            previousFolders[folder.id].map { $0 != folder.isExpanded } ?? false
        }) {
            return true
        }
        let previousEmptyGroups = Dictionary(uniqueKeysWithValues: previous.emptyGroups.map { ($0.id, $0.isExpanded) })
        return emptyGroups.contains { group in
            previousEmptyGroups[group.id].map { $0 != group.isExpanded } ?? false
        }
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
    case fileFooter(fileID: String)
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
    case fileFooter(String)
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
    guard !(hitView is NSButton), !(hitView is DiffSelectableTextView) else {
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

private extension NSView {
    var isInsideLiveScrollingDiff: Bool {
        (enclosingScrollView as? DiffStackScrollView)?.isLiveScrolling == true
    }
}

@MainActor
private extension NSView {
    private static var hoverToolTipAssociationKey: UInt8 = 0

    var diffHoverToolTip: String? {
        get {
            objc_getAssociatedObject(self, &Self.hoverToolTipAssociationKey) as? String
        }
        set {
            let normalized = (newValue?.isEmpty == true) ? nil : newValue
            objc_setAssociatedObject(
                self,
                &Self.hoverToolTipAssociationKey,
                normalized,
                .OBJC_ASSOCIATION_COPY_NONATOMIC
            )
            if DiffHoverDispatcher.isActivelyHostingToolTip(on: self) {
                toolTip = normalized
            } else if toolTip != nil {
                toolTip = nil
            }
        }
    }
}

@MainActor
private protocol DiffHoverControlTarget: AnyObject {
    func setPointerHovered(_ hovered: Bool)
}

@MainActor
private protocol DiffHoverCellTarget: AnyObject {
    func setPointerHovered(_ hovered: Bool)
}

@MainActor
private final class DiffHoverDispatcher {
    private static var activeToolTipViews = NSHashTable<NSView>.weakObjects()

    static func isActivelyHostingToolTip(on view: NSView) -> Bool {
        activeToolTipViews.contains(view)
    }

    private weak var hoveredControl: (NSView & DiffHoverControlTarget)?
    private weak var hoveredCell: (NSView & DiffHoverCellTarget)?
    private weak var hoveredToolTipView: NSView?

    func update(hitView: NSView?) {
        var nextControl: (NSView & DiffHoverControlTarget)?
        var nextCell: (NSView & DiffHoverCellTarget)?
        var nextToolTipView: NSView?
        var cursor = hitView
        while let current = cursor {
            if nextControl == nil, let control = current as? (NSView & DiffHoverControlTarget) {
                nextControl = control
            }
            if nextCell == nil, let cell = current as? (NSView & DiffHoverCellTarget) {
                nextCell = cell
            }
            if nextToolTipView == nil, current.diffHoverToolTip != nil {
                nextToolTipView = current
            }
            if nextControl != nil && nextCell != nil && nextToolTipView != nil {
                break
            }
            cursor = current.superview
        }
        if hoveredControl !== nextControl {
            hoveredControl?.setPointerHovered(false)
            hoveredControl = nextControl
            hoveredControl?.setPointerHovered(true)
        }
        if hoveredCell !== nextCell {
            hoveredCell?.setPointerHovered(false)
            hoveredCell = nextCell
            hoveredCell?.setPointerHovered(true)
        }
        if hoveredToolTipView !== nextToolTipView {
            if let previous = hoveredToolTipView {
                Self.activeToolTipViews.remove(previous)
                previous.toolTip = nil
            }
            hoveredToolTipView = nextToolTipView
            if let next = nextToolTipView {
                Self.activeToolTipViews.add(next)
                next.toolTip = next.diffHoverToolTip
            }
        }
    }

    func clear() {
        if let control = hoveredControl {
            hoveredControl = nil
            control.setPointerHovered(false)
        }
        if let cell = hoveredCell {
            hoveredCell = nil
            cell.setPointerHovered(false)
        }
        if let tipView = hoveredToolTipView {
            hoveredToolTipView = nil
            Self.activeToolTipViews.remove(tipView)
            tipView.toolTip = nil
        }
    }
}

/// 表格拿到键盘焦点后系统会把选中行铺成强调蓝，直接盖掉 hunk 标题文字和代码底色。
/// 选中行一律用弱化外观，diff 自己的增删色和选区色才是这块区域的主角。
private final class DiffTableRowView: NSTableRowView {
    override var isOpaque: Bool { true }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func updateLayer() {
        layer?.backgroundColor = nil
    }

    override func drawBackground(in dirtyRect: NSRect) {}

    override func drawSelection(in dirtyRect: NSRect) {}
}

private final class DiffCopyingTableView: NSTableView {
    var copyTextProvider: ((IndexSet) -> String)?
    var rowClickHandler: ((Int) -> Bool)?
    var dynamicMenuProvider: ((Int, IndexSet, Bool) -> NSMenu?)?
    var hunkNavigationHandler: ((Int) -> Bool)?
    var cancelPendingActionHandler: (() -> Bool)?
    var codeSelectionHandler: ((NSEvent, DiffSelectableTextView) -> Bool)?
    var clearCodeSelectionHandler: (() -> Void)?
    var keepsCodeSelectionForMenu: ((Int) -> Bool)?
    private var isShowingIBeamCursor = false
    private let hoverDispatcher = DiffHoverDispatcher()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [
                    .cursorUpdate,
                    .mouseMoved,
                    .mouseEnteredAndExited,
                    .activeInKeyWindow,
                    .inVisibleRect
                ],
                owner: self
            )
        )
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func cursorUpdate(with event: NSEvent) {
        updatePointerState(windowPoint: event.locationInWindow, forceCursorSet: true)
    }

    override func mouseMoved(with event: NSEvent) {
        guard !isInsideLiveScrollingDiff else {
            return
        }
        updatePointerState(windowPoint: event.locationInWindow, forceCursorSet: false)
    }

    override func mouseExited(with event: NSEvent) {
        clearPointerHover()
    }

    func clearPointerHover() {
        hoverDispatcher.clear()
        if isShowingIBeamCursor {
            isShowingIBeamCursor = false
            NSCursor.arrow.set()
        }
    }

    func refreshPointerHover(windowPoint: NSPoint) {
        guard !isInsideLiveScrollingDiff else {
            return
        }
        updatePointerState(windowPoint: windowPoint, forceCursorSet: false)
    }

    private func hitViewForPointer(windowPoint: NSPoint) -> NSView? {
        if let scrollView = enclosingScrollView {
            let scrollPoint = scrollView.convert(windowPoint, from: nil)
            guard let hit = scrollView.hitTest(scrollPoint),
                  hit === self || hit.isDescendant(of: self) else {
                return nil
            }
            return hit
        }
        let point = convert(windowPoint, from: nil)
        return hitTest(point)
    }

    private func updatePointerState(windowPoint: NSPoint, forceCursorSet: Bool) {
        let hitView = hitViewForPointer(windowPoint: windowPoint)
        if !isInsideLiveScrollingDiff {
            hoverDispatcher.update(hitView: hitView)
        }
        let wantsIBeam = hitView is DiffSelectableTextView
        guard forceCursorSet || wantsIBeam != isShowingIBeamCursor else {
            return
        }
        isShowingIBeamCursor = wantsIBeam
        if wantsIBeam {
            NSCursor.iBeam.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        (enclosingScrollView as? DiffStackScrollView)?.cancelFlingSubstepping()
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
        if moveReviewKeyboardFocus(from: self, event: event) {
            return
        }
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
        let hadSelection = selectedRowIndexes.contains(clickedRow) || keepsCodeSelectionForMenu?(clickedRow) == true
        if !hadSelection {
            selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }
        return dynamicMenuProvider?(clickedRow, selectedRowIndexes, hadSelection) ?? super.menu(for: event)
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

private final class DiffSelectionMenuCommand: NSObject {
    let actionID: String
    let choiceID: String?
    let excerpt: DiffSelectionExcerpt

    init(actionID: String, choiceID: String?, excerpt: DiffSelectionExcerpt) {
        self.actionID = actionID
        self.choiceID = choiceID
        self.excerpt = excerpt
    }
}

/// 选中代码后浮在选区旁的操作条。它叠在表格上方，出现、消失都不改变任何行的位置；
/// 按钮的标题和宽度只随操作列表变化，不随选区或目标会话数变化。
private final class DiffSelectionActionBar: NSView {
    private static let padding: CGFloat = 3

    var actionHandler: ((DiffSelectionAction, NSButton) -> Void)?
    private var actions: [DiffSelectionAction] = []
    private var buttons: [ReviewActionButton] = []
    private let hoverDispatcher = DiffHoverDispatcher()

    override var isFlipped: Bool { true }

    override var isHidden: Bool {
        get { super.isHidden }
        set {
            if newValue != super.isHidden, newValue {
                hoverDispatcher.clear()
            }
            super.isHidden = newValue
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = ReviewControlMetrics.cornerRadius + Self.padding
        layer?.borderWidth = 1
        layer?.shadowOpacity = 0.14
        layer?.shadowRadius = 5
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Selection Actions")
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self
            )
        )
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hoverDispatcher.update(hitView: hitTest(point))
    }

    override func mouseExited(with event: NSEvent) {
        hoverDispatcher.clear()
    }

    required init?(coder: NSCoder) {
        nil
    }

    var preferredSize: NSSize {
        let widths = buttons.map(\.preferredWidth)
        let spacing = CGFloat(max(0, widths.count - 1)) * 2
        return NSSize(
            width: ceil(widths.reduce(0, +) + spacing + Self.padding * 2),
            height: ReviewControlMetrics.height + Self.padding * 2
        )
    }

    func update(actions: [DiffSelectionAction]) {
        self.actions = actions
        if buttons.count != actions.count {
            buttons.forEach { $0.removeFromSuperview() }
            buttons = actions.indices.map { index in
                let button = ReviewActionButton()
                button.tag = index
                button.target = self
                button.action = #selector(buttonPressed(_:))
                addSubview(button)
                return button
            }
        }
        for (button, action) in zip(buttons, actions) {
            button.title = action.title
            button.image = NSImage(systemSymbolName: action.systemImage, accessibilityDescription: nil)
            button.isEnabled = action.isEnabled
            button.toolTip = action.help
            button.setAccessibilityLabel(action.title)
            button.setAccessibilityHelp(action.help)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var x = Self.padding
        for button in buttons {
            let width = button.preferredWidth
            button.frame = NSRect(x: x, y: Self.padding, width: width, height: ReviewControlMetrics.height)
            x += width + 2
        }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = AgentGitPalette.card.cgColor
            layer?.borderColor = AgentGitPalette.cardBorder.cgColor
            layer?.shadowColor = NSColor.black.cgColor
        }
    }

    /// 点在按钮之间的空白处时不要漏给下面的代码行。
    override func mouseDown(with event: NSEvent) {}

    @objc private func buttonPressed(_ sender: NSButton) {
        guard actions.indices.contains(sender.tag) else {
            return
        }
        actionHandler?(actions[sender.tag], sender)
    }
}

@MainActor
private func makeDisclosureView() -> DiffDisclosureView {
    DiffDisclosureView()
}

final class DiffDisclosureView: NSView {
    private let glyph = CAShapeLayer()
    private var isExpanded: Bool?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        glyph.bounds = CGRect(x: 0, y: 0, width: 13, height: 13)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 4.75, y: 3))
        path.addLine(to: CGPoint(x: 8.25, y: 6.5))
        path.addLine(to: CGPoint(x: 4.75, y: 10))
        glyph.path = path
        glyph.fillColor = nil
        glyph.lineWidth = 1.2
        glyph.lineCap = .round
        glyph.lineJoin = .round
        layer?.addSublayer(glyph)
        setAccessibilityElement(false)
        updateColor()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let targetPosition = CGPoint(x: bounds.midX, y: bounds.midY)
        let targetScale = window?.backingScaleFactor ?? 2
        guard glyph.position != targetPosition || glyph.contentsScale != targetScale else {
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyph.position = targetPosition
        glyph.contentsScale = targetScale
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColor()
    }

    private func updateColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            glyph.strokeColor = NSColor.tertiaryLabelColor.cgColor
            CATransaction.commit()
        }
    }

    func setExpanded(_ expanded: Bool) {
        guard isExpanded != expanded else { return }
        let canAnimate = isExpanded != nil && window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let previous = glyph.presentation()?.transform ?? glyph.transform
        isExpanded = expanded
        let rotation = CATransform3DMakeRotation(expanded ? .pi / 2 : 0, 0, 0, 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyph.transform = rotation
        glyph.removeAnimation(forKey: "disclosure-rotation")
        CATransaction.commit()
        if canAnimate {
            let animation = CABasicAnimation(keyPath: "transform")
            animation.fromValue = NSValue(caTransform3D: previous)
            animation.toValue = NSValue(caTransform3D: rotation)
            animation.duration = WorkspaceMotion.hoverDuration
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            glyph.add(animation, forKey: "disclosure-rotation")
        }
    }
}

private final class DiffStickyClipView: NSView {
    private var groupHeight: CGFloat = 0
    private var fileHeight: CGFloat = 0
    private let hoverDispatcher = DiffHoverDispatcher()

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override var isHidden: Bool {
        get { super.isHidden }
        set {
            if newValue != super.isHidden, newValue {
                hoverDispatcher.clear()
            }
            super.isHidden = newValue
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self
            )
        )
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func mouseMoved(with event: NSEvent) {
        guard !isInsideLiveScrollingDiff else {
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        hoverDispatcher.update(hitView: hitTest(point))
    }

    override func mouseExited(with event: NSEvent) {
        hoverDispatcher.clear()
    }

    override func draw(_ dirtyRect: NSRect) {
        AgentGitPalette.groupHeader.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: groupHeight).fill()
        AgentGitPalette.fileHeader.setFill()
        NSRect(x: 0, y: groupHeight, width: bounds.width, height: fileHeight).fill()
        if fileHeight > 0 {
            AgentGitPalette.reviewDivider.setFill()
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
    private var renderedSummary: DiffStackSummary?
    private var setAllFilesExpandedHandler: ((Bool) -> Void)?

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
        setAllFilesExpandedHandler = onSetAllFilesExpanded
        guard renderedSummary != summary || hostingView == nil else {
            return
        }
        renderedSummary = summary
        let content = DiffStackSummaryContent(
            summary: summary,
            onSetAllFilesExpanded: { [weak self] isExpanded in
                self?.setAllFilesExpandedHandler?(isExpanded)
            }
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
    @MainActor private static let defaultButtonFont = AgentGitTypography.interface(ofSize: 11.5, weight: .medium)
    @MainActor private static let discardAllWidth = ReviewButtonCell.preferredWidth(
        title: "Discard All",
        image: nil,
        font: defaultButtonFont
    )

    var clickHandler: ((String) -> Void)?

    private let chevron = makeDisclosureView()
    private let label = DiffTextField(
        font: AgentGitTypography.interface(ofSize: AgentGitTypography.interfaceSize, weight: .medium),
        textColor: .labelColor,
        alignment: .left,
        selectable: false
    )
    private var groupID = ""
    private let stageButton = ReviewActionButton(title: "Stage All", target: nil, action: nil)
    private let discardButton = ReviewActionButton(title: "Discard All", target: nil, action: nil)
    private var allChangesHandler: ((GitAllChangesAction) -> Void)?
    /// 和文件、hunk 的 Discard 一样原地二次确认：第一次点击变成 Confirm，3 秒内再点才执行。
    private var discardConfirmationTimer: Timer?
    private var isConfirmingDiscard: Bool { discardConfirmationTimer != nil }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        canDrawSubviewsIntoLayer = true
        addSubview(chevron)
        addSubview(label)
        for button in [stageButton, discardButton] {
            button.bezelStyle = .inline
            button.target = self
            button.isHidden = true
            addSubview(button)
        }
        stageButton.action = #selector(stageAll)
        stageButton.isPrimary = true
        discardButton.action = #selector(discardAll)
        discardButton.isDestructive = true
        stageButton.diffHoverToolTip = "Stage all modified, deleted, and untracked files in this worktree"
        resetDiscardConfirmation()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        stageButton.setPointerHovered(false)
        discardButton.setPointerHovered(false)
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
        let stageWidth = stageButton.preferredWidth
        let discardWidth = Self.discardAllWidth
        let actionsWidth = stageWidth + ReviewControlMetrics.spacing + discardWidth
        let discardX = bounds.width - ReviewControlMetrics.trailingInset - discardWidth
        let actionY = max(0, (bounds.height - ReviewControlMetrics.height) / 2)
        chevron.frame = NSRect(x: 14, y: (bounds.height - 13) / 2, width: 13, height: 13)
        label.frame = NSRect(
            x: 36,
            y: (bounds.height - 16) / 2,
            width: max(0, bounds.width - 36 - (groupID == "working" ? actionsWidth + ReviewControlMetrics.trailingInset + 12 : 7)),
            height: 16
        )
        stageButton.frame = NSRect(x: discardX - ReviewControlMetrics.spacing - stageWidth, y: actionY, width: stageWidth, height: ReviewControlMetrics.height)
        discardButton.frame = NSRect(x: discardX, y: actionY, width: discardWidth, height: ReviewControlMetrics.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        AgentGitPalette.groupHeader.setFill()
        dirtyRect.fill()
        AgentGitPalette.reviewDivider.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        super.draw(dirtyRect)
    }

    func update(group: DiffStackGroup, count: Int) {
        if groupID != group.id {
            resetDiscardConfirmation()
        }
        groupID = group.id
        stageButton.isHidden = groupID != "working"
        discardButton.isHidden = groupID != "working"
        chevron.setExpanded(group.isExpanded)
        label.attributedStringValue = NSAttributedString(
            string: "\(group.title ?? "") · \(count)",
            attributes: [
                .font: Self.defaultButtonFont,
                .foregroundColor: AgentGitPalette.commitPrimaryText
            ]
        )
        diffHoverToolTip = group.isExpanded
            ? "Collapse all \(countedLabel(count, singular: "file"))"
            : "Expand all \(countedLabel(count, singular: "file"))"
        needsLayout = true
        needsDisplay = true
    }

    func setActions(enabled: Bool, handler: @escaping (GitAllChangesAction) -> Void) {
        allChangesHandler = handler
        stageButton.isEnabled = enabled
        discardButton.isEnabled = enabled
        if !enabled {
            resetDiscardConfirmation()
        }
    }

    @objc private func stageAll() {
        resetDiscardConfirmation()
        allChangesHandler?(.stage)
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
        discardButton.title = "Confirm"
        discardButton.isConfirming = true
        discardButton.diffHoverToolTip = "Press again to discard staged, unstaged, and untracked files; recovery copies and a staged patch are saved in Trash"
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
        discardButton.isConfirming = false
        discardButton.title = "Discard All"
        discardButton.diffHoverToolTip = "Discard all uncommitted changes in this worktree; requires confirmation and saves recovery copies in Trash"
        discardButton.setAccessibilityLabel("Discard All")
    }
}

private final class DiffFolderCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("diff-folder")
    private static let folderSymbolConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
    @MainActor private static let expandedFolderImage = NSImage(
        systemSymbolName: "folder.fill",
        accessibilityDescription: nil
    )?.withSymbolConfiguration(folderSymbolConfig)
    @MainActor private static let collapsedFolderImage = NSImage(
        systemSymbolName: "folder",
        accessibilityDescription: nil
    )?.withSymbolConfiguration(folderSymbolConfig)

    private let chevron = makeDisclosureView()
    private let icon = NSImageView()
    private let label = DiffTextField(
        font: AgentGitTypography.interface(ofSize: AgentGitTypography.interfaceSize, weight: .regular),
        textColor: .secondaryLabelColor,
        alignment: .left,
        selectable: false
    )
    private var renderedFolder: DiffStackFolder?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        canDrawSubviewsIntoLayer = true
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
        AgentGitPalette.reviewDivider.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        super.draw(dirtyRect)
    }

    func update(folder: DiffStackFolder) {
        guard renderedFolder != folder else {
            return
        }
        renderedFolder = folder
        chevron.setExpanded(folder.isExpanded)
        icon.image = folder.isExpanded ? Self.expandedFolderImage : Self.collapsedFolderImage
        label.stringValue = folder.title
        diffHoverToolTip = folder.title
        setAccessibilityLabel(folder.title)
        setAccessibilityHelp(folder.isExpanded ? "Collapse folder" : "Expand folder")
        needsLayout = true
        needsDisplay = true
    }
}

private final class ReviewButtonCell: NSButtonCell {
    @MainActor private static let titleParagraphStyle: NSParagraphStyle = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byClipping
        return paragraph
    }()

    static func preferredWidth(title: String, image: NSImage?, font: NSFont) -> CGFloat {
        if title.isEmpty { return ReviewControlMetrics.height }
        let textWidth = (title as NSString).size(withAttributes: [.font: font]).width
        let iconWidth = image == nil ? 0 : ReviewControlMetrics.iconSize
        let gap = image != nil && !title.isEmpty ? ReviewControlMetrics.iconTextSpacing : 0
        return max(ReviewControlMetrics.height, ceil(textWidth + iconWidth + gap + ReviewControlMetrics.horizontalPadding * 2))
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        guard let button = controlView as? NSButton else {
            super.drawInterior(withFrame: cellFrame, in: controlView)
            return
        }
        let text = button.imagePosition == .imageOnly ? "" : button.title
        let image = button.imagePosition == .noImage ? nil : button.image
        let font = button.font ?? AgentGitTypography.interface(ofSize: 11.5, weight: .medium)
        let textWidth = text.isEmpty ? 0 : (text as NSString).size(withAttributes: [.font: font]).width
        let iconWidth = image == nil ? 0 : ReviewControlMetrics.iconSize
        let gap = image != nil && !text.isEmpty ? ReviewControlMetrics.iconTextSpacing : 0
        let contentWidth = textWidth + iconWidth + gap
        let leading = cellFrame.midX - contentWidth / 2

        if let image {
            super.drawImage(image, withFrame: NSRect(
                x: leading,
                y: cellFrame.midY - ReviewControlMetrics.iconSize / 2,
                width: ReviewControlMetrics.iconSize,
                height: ReviewControlMetrics.iconSize
            ), in: controlView)
        }
        if !text.isEmpty {
            let title = NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: button.contentTintColor ?? .labelColor,
                .paragraphStyle: Self.titleParagraphStyle
            ])
            _ = super.drawTitle(title, withFrame: NSRect(
                x: leading + iconWidth + gap,
                y: cellFrame.minY,
                width: ceil(textWidth),
                height: cellFrame.height
            ), in: controlView)
        }
    }
}

@MainActor
private func moveReviewKeyboardFocus(from view: NSView, event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
    guard event.keyCode == 48, modifiers.isEmpty || modifiers == .shift,
          let window = view.window else { return false }
    var ancestor: NSView? = view
    while let candidate = ancestor {
        if let review = candidate as? DiffStackScrollView,
           review.moveControlFocus(from: view, backwards: modifiers == .shift) {
            return true
        }
        ancestor = candidate.superview
    }
    window.recalculateKeyViewLoop()
    if modifiers == .shift { window.selectPreviousKeyView(view) }
    else { window.selectNextKeyView(view) }
    return true
}

private class ReviewControlButton: NSButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) { nil }

    fileprivate func drawInteractionBackground(_ color: NSColor?) {
        guard let color else { return }
        color.setFill()
        NSBezierPath(
            roundedRect: bounds,
            xRadius: ReviewControlMetrics.cornerRadius,
            yRadius: ReviewControlMetrics.cornerRadius
        ).fill()
    }

    override var isEnabled: Bool {
        get { super.isEnabled }
        set {
            guard newValue != super.isEnabled else { return }
            if !newValue, let window, window.firstResponder === self {
                // 禁用前先交回表格，避免在 SwiftUI 更新中触发宿主视图的焦点树遍历。
                var ancestor = superview
                while let view = ancestor, !(view is DiffStackScrollView) {
                    ancestor = view.superview
                }
                if let review = ancestor as? DiffStackScrollView {
                    review.moveFocusToReviewContent()
                } else {
                    window.makeFirstResponder(nil)
                }
            }
            super.isEnabled = newValue
        }
    }

    override var acceptsFirstResponder: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }
    override var canBecomeKeyView: Bool {
        acceptsFirstResponder && window != nil && !visibleRect.isEmpty
    }

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

    override func keyDown(with event: NSEvent) {
        if moveReviewKeyboardFocus(from: self, event: event) { return }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if window?.firstResponder === self {
            AgentGitPalette.focusIndicator.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: ReviewControlMetrics.cornerRadius, yRadius: ReviewControlMetrics.cornerRadius)
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }
}

private final class ReviewGlyphButton: ReviewControlButton, DiffHoverControlTarget {
    private var isHovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = ReviewButtonCell(textCell: "")
        setButtonType(.momentaryPushIn)
        isBordered = false
        bezelStyle = .inline
        focusRingType = .none
        imageScaling = .scaleProportionallyDown
    }

    required init?(coder: NSCoder) { nil }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            isHovered = false
        }
        super.viewWillMove(toWindow: newWindow)
    }

    func setPointerHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = isEnabled && (isHovered || isHighlighted || state == .on)
        drawInteractionBackground(
            highlighted ? (isHighlighted ? AgentGitPalette.controlPressed : AgentGitPalette.controlHover) : nil
        )
        super.draw(dirtyRect)
    }
}

private final class ReviewActionButton: ReviewControlButton, DiffHoverControlTarget {
    @MainActor private static let defaultFont = AgentGitTypography.interface(ofSize: 11.5, weight: .medium)
    @MainActor static let defaultDiscardWidth = ReviewButtonCell.preferredWidth(
        title: "Confirm",
        image: nil,
        font: defaultFont
    )

    var isConfirming = false { didSet { refreshTintColor(); needsDisplay = true } }
    var isPrimary = false { didSet { refreshTintColor(); needsDisplay = true } }
    var isDestructive = false { didSet { refreshTintColor(); needsDisplay = true } }
    private var isHovered = false

    override var isEnabled: Bool {
        get { super.isEnabled }
        set {
            super.isEnabled = newValue
            refreshTintColor()
        }
    }

    var preferredWidth: CGFloat {
        ReviewButtonCell.preferredWidth(
            title: imagePosition == .imageOnly ? "" : title,
            image: imagePosition == .noImage ? nil : image,
            font: font ?? Self.defaultFont
        )
    }

    var discardWidth: CGFloat {
        if font == nil || font == Self.defaultFont {
            return Self.defaultDiscardWidth
        }
        return ReviewButtonCell.preferredWidth(
            title: "Confirm", image: nil,
            font: font ?? Self.defaultFont
        )
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = ReviewButtonCell(textCell: "")
        setButtonType(.momentaryPushIn)
        isBordered = false
        bezelStyle = .inline
        controlSize = .small
        focusRingType = .none
        font = Self.defaultFont
        imagePosition = .imageLeft
        imageScaling = .scaleProportionallyDown
        refreshTintColor()
    }

    required init?(coder: NSCoder) { nil }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, isHovered {
            isHovered = false
            refreshTintColor()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    func setPointerHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        refreshTintColor()
        needsDisplay = true
    }

    private var desiredForegroundColor: NSColor {
        let danger = isEnabled && (isConfirming || (isDestructive && isHovered))
        if danger {
            return AgentGitPalette.reviewActionConfirmationText
        }
        if isPrimary || isHovered {
            return AgentGitPalette.activeControl
        }
        return AgentGitPalette.controlText
    }

    private func refreshTintColor() {
        let target = isEnabled ? desiredForegroundColor : AgentGitPalette.controlDisabled
        if contentTintColor != target {
            contentTintColor = target
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let danger = isEnabled && (isConfirming || (isDestructive && isHovered))
        let foreground = desiredForegroundColor
        if danger {
            drawInteractionBackground(AgentGitPalette.reviewActionConfirmationBackground)
        } else if isEnabled && (isHovered || isHighlighted || state == .on) {
            drawInteractionBackground(
                state == .on ? ReviewWorkspaceStyle.selection : isHighlighted ? AgentGitPalette.controlPressed : AgentGitPalette.controlHover
            )
        }
        if isEnabled && isConfirming {
            let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: ReviewControlMetrics.cornerRadius, yRadius: ReviewControlMetrics.cornerRadius)
            foreground.withAlphaComponent(0.3).setStroke()
            shape.lineWidth = 0.7
            shape.stroke()
        }
        let targetTint = isEnabled ? foreground : AgentGitPalette.controlDisabled
        if contentTintColor != targetTint {
            contentTintColor = targetTint
        }
        super.draw(dirtyRect)
    }
}

private final class DiffFileStatsView: NSView {
    @MainActor static let font = ReviewWorkspaceStyle.nativeFont(13)
    @MainActor private static let ctFont: CTFont = font as CTFont
    @MainActor private static let ascent: CGFloat = CTFontGetAscent(ctFont)
    @MainActor private static let descent: CGFloat = CTFontGetDescent(ctFont)
    private static let spacing: CGFloat = 6

    private var hasStats = false
    private var addedLineCount: Int?
    private var deletedLineCount: Int?
    private var cachedPreferredWidth: CGFloat = 16
    private var cachedAppearance: DiffAppearanceVariant?
    private var cachedLoadingLine: CTLine?
    private var cachedAddedLine: CTLine?
    private var cachedDeletedLine: CTLine?
    private var cachedAddedWidth: CGFloat = 0

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("file-diff-stats")
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        recomputeMetrics()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(diff: GitFileDiff?) {
        let nextAdded = diff?.addedLineCount
        let nextDeleted = diff?.deletedLineCount
        let nextHasStats = diff != nil
        guard hasStats != nextHasStats
                || addedLineCount != nextAdded
                || deletedLineCount != nextDeleted else {
            return
        }
        hasStats = nextHasStats
        addedLineCount = nextAdded
        deletedLineCount = nextDeleted
        cachedAppearance = nil
        cachedLoadingLine = nil
        cachedAddedLine = nil
        cachedDeletedLine = nil
        recomputeMetrics()
        if let diff {
            diffHoverToolTip = "+\(diff.addedLineCount)  -\(diff.deletedLineCount)"
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
            diffHoverToolTip = nil
            setAccessibilityLabel("Diff statistics loading")
        }
        needsDisplay = true
    }

    /// 统计紧跟在路径后面，宽度按实际数字算。
    var preferredWidth: CGFloat {
        cachedPreferredWidth
    }

    private func recomputeMetrics() {
        let appearance = DiffAppearanceVariant(appearance: effectiveAppearance)
        ensureCTLines(for: appearance)
        if hasStats {
            let deletedWidth = cachedDeletedLine.map {
                CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil))
            } ?? 0
            cachedPreferredWidth = ceil(cachedAddedWidth + Self.spacing + deletedWidth) + 2
        } else {
            let loadingWidth = cachedLoadingLine.map {
                CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil))
            } ?? 14
            cachedPreferredWidth = ceil(loadingWidth) + 2
        }
    }

    private func ensureCTLines(for appearance: DiffAppearanceVariant) {
        guard cachedAppearance != appearance else { return }
        cachedAppearance = appearance
        if let addedLineCount, let deletedLineCount {
            let added = Self.makeCTLine(
                text: "+\(addedLineCount)",
                color: appearance.resolveCGColor(AgentGitPalette.additionText)
            )
            cachedAddedLine = added
            cachedAddedWidth = CGFloat(CTLineGetTypographicBounds(added, nil, nil, nil))
            cachedDeletedLine = Self.makeCTLine(
                text: "-\(deletedLineCount)",
                color: appearance.resolveCGColor(AgentGitPalette.deletionText)
            )
            cachedLoadingLine = nil
        } else {
            cachedLoadingLine = Self.makeCTLine(
                text: "…",
                color: appearance.resolveCGColor(AgentGitPalette.reviewTertiaryText)
            )
            cachedAddedLine = nil
            cachedDeletedLine = nil
            cachedAddedWidth = 0
        }
    }

    private static func makeCTLine(text: String, color: CGColor) -> CTLine {
        let cfText = text as CFString
        let length = CFStringGetLength(cfText)
        let attr = CFAttributedStringCreateMutable(kCFAllocatorDefault, length)!
        CFAttributedStringBeginEditing(attr)
        CFAttributedStringReplaceString(attr, CFRange(location: 0, length: 0), cfText)
        let range = CFRange(location: 0, length: length)
        CFAttributedStringSetAttribute(attr, range, kCTFontAttributeName, ctFont)
        CFAttributedStringSetAttribute(attr, range, kCTForegroundColorAttributeName, color)
        CFAttributedStringEndEditing(attr)
        return CTLineCreateWithAttributedString(attr)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        let appearance = DiffAppearanceVariant(appearance: effectiveAppearance)
        ensureCTLines(for: appearance)
        let baselineY = round(((bounds.height + Self.ascent - Self.descent) * 0.5) * 2) * 0.5
        context.saveGState()
        defer { context.restoreGState() }
        if let addedLine = cachedAddedLine, let deletedLine = cachedDeletedLine {
            drawFlippedCTLine(addedLine, at: CGPoint(x: 0, y: baselineY), in: context)
            drawFlippedCTLine(deletedLine, at: CGPoint(x: cachedAddedWidth + Self.spacing, y: baselineY), in: context)
        } else if let loadingLine = cachedLoadingLine {
            drawFlippedCTLine(loadingLine, at: CGPoint(x: 0, y: baselineY), in: context)
        }
    }
}

private final class DiffFileCellView: NSTableCellView, DiffHoverCellTarget {
    private static let discardConfirmationDuration: TimeInterval = 3
    static let identifier = NSUserInterfaceItemIdentifier("diff-file")

    var clickHandler: ((String) -> Void)?
    var reviewHandler: ((String) -> Void)?
    var wholeFileHandler: ((String) -> Void)?
    var actionHandler: ((String, GitPendingSelectionAction) -> Void)?
    var menuHandler: ((String) -> NSMenu?)?

    private let chevron = makeDisclosureView()
    private let statusIcon = NSImageView()
    private let statusText = DiffTextField(
        font: .monospacedSystemFont(ofSize: 10, weight: .bold),
        textColor: .secondaryLabelColor,
        alignment: .center,
        selectable: false
    )
    private let title = DiffTextField(
        font: ReviewWorkspaceStyle.nativeFont(ReviewWorkspaceStyle.fileTitleSize),
        textColor: ReviewWorkspaceStyle.primary,
        alignment: .left,
        selectable: false
    )
    private let directoryLabel = DiffTextField(
        font: ReviewWorkspaceStyle.nativeFont(13),
        textColor: AgentGitPalette.reviewTertiaryText,
        alignment: .left,
        selectable: false
    )
    private let stats = DiffFileStatsView()
    private var statusColor = NSColor.secondaryLabelColor
    private let menuButton = ReviewGlyphButton(title: "", target: nil, action: nil)
    private let wholeFileButton = ReviewActionButton(title: "Whole file", target: nil, action: nil)
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
    private struct RenderedHeaderKey: Equatable {
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
        let canApplyPrimaryAction: Bool
        let canDiscard: Bool
        let isMutationEnabled: Bool
        let mutationSnapshotID: DiffReviewSnapshotID?
        let mutationMode: DiffStackMutationMode?
        let hasDiff: Bool
        let addedLineCount: Int?
        let deletedLineCount: Int?
    }

    private static let wholeFileDocImage = NSImage(
        systemSymbolName: "doc.text",
        accessibilityDescription: nil
    )
    private static let wholeFileExpandedWidth: CGFloat = {
        let font = ReviewWorkspaceStyle.nativeFont(12)
        return ["Whole file", "Changes only", "Loading…"].map {
            ReviewButtonCell.preferredWidth(
                title: $0,
                image: ReviewIcon.expand.actionImage,
                font: font
            )
        }.max() ?? ReviewControlMetrics.height
    }()
    private static let statusSymbolConfig = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
    private static let codeStatusImage = NSImage(
        systemSymbolName: "chevron.left.forwardslash.chevron.right",
        accessibilityDescription: nil
    )?.withSymbolConfiguration(statusSymbolConfig)
    private static let conflictStatusImage = NSImage(
        systemSymbolName: "exclamationmark.triangle.fill",
        accessibilityDescription: nil
    )?.withSymbolConfiguration(statusSymbolConfig)

    @MainActor private static let directoryFont = ReviewWorkspaceStyle.nativeFont(13)
    @MainActor private static let directoryCTFont: CTFont = directoryFont as CTFont
    @MainActor private static let titleParagraphStyle: NSParagraphStyle = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        return paragraph
    }()

    private var fileMutationActionsEnabled = true
    private var globalMutationActionsEnabled = true
    private var isHovered = false
    private var renderedHeaderKey: RenderedHeaderKey?
    private var cachedTitleWidth: CGFloat = 0
    private var cachedDirectoryWidth: CGFloat = 0

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        canDrawSubviewsIntoLayer = true
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
        resetDiscardConfirmation()
        title.lineBreakMode = .byTruncatingMiddle
        title.usesSingleLineMode = true
        title.cell?.truncatesLastVisibleLine = true
        directoryLabel.usesSingleLineMode = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        setPointerHovered(false)
        wholeFileButton.setPointerHovered(false)
        primaryButton.setPointerHovered(false)
        discardButton.setPointerHovered(false)
        reviewButton.setPointerHovered(false)
        menuButton.setPointerHovered(false)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            isHovered = false
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

    func setPointerHovered(_ hovered: Bool) {
        guard isHovered != hovered else {
            return
        }
        isHovered = hovered
        needsDisplay = true
    }

    /// 表格内的行由 NSTableView 统一派发点击，只有吸顶实例会装 clickHandler。
    override func mouseDown(with event: NSEvent) {
        guard let clickHandler else {
            super.mouseDown(with: event)
            return
        }
        clickHandler(fileID)
    }

    /// 标题行只有一行：箭头、代码图标、文件名、目录、增删统计依次排开，文件操作靠右。
    /// 空间不够时先压缩目录，再压缩文件名；按钮位置固定在右侧，不随文字长短移动。
    override func layout() {
        super.layout()
        let compact = bounds.width < 720
        wholeFileButton.imagePosition = compact ? .imageOnly : .imageLeft
        let wholeFileWidth: CGFloat = compact ? ReviewControlMetrics.height : Self.wholeFileExpandedWidth
        let primaryWidth = ReviewControlMetrics.height
        let discardWidth = discardButton.discardWidth
        let widths = [wholeFileWidth, primaryWidth, discardWidth, ReviewControlMetrics.height, ReviewControlMetrics.height]
        let controlsWidth = widths.reduce(0, +) + CGFloat(widths.filter { $0 > 0 }.count - 1) * ReviewControlMetrics.spacing
        let controlsX = max(0, bounds.width - ReviewControlMetrics.trailingInset - controlsWidth)
        chevron.frame = NSRect(x: 14, y: headerCenterY(13), width: 13, height: 13)
        statusIcon.frame = NSRect(x: 33, y: headerCenterY(16), width: 16, height: 16)
        statusText.frame = .zero

        let textX: CGFloat = 55
        let textLimit = max(textX, controlsX - 12)
        stats.isHidden = bounds.width < 420
        let statsWidth = stats.isHidden ? 0 : stats.preferredWidth
        let statsSpacing: CGFloat = stats.isHidden ? 0 : 10
        let nameWidth = cachedTitleWidth
        let directoryWidth = directoryLabel.isHidden ? 0 : cachedDirectoryWidth
        let directorySpacing: CGFloat = directoryLabel.isHidden ? 0 : 8
        var available = textLimit - textX - statsWidth - statsSpacing
        let shownNameWidth = min(nameWidth, max(0, available))
        available -= shownNameWidth + directorySpacing
        let shownDirectoryWidth = min(directoryWidth, max(0, available))
        let rowY = headerCenterY(19)
        title.frame = NSRect(x: textX, y: rowY, width: shownNameWidth, height: 19)
        directoryLabel.frame = NSRect(
            x: title.frame.maxX + directorySpacing,
            y: rowY,
            width: shownDirectoryWidth < 24 ? 0 : shownDirectoryWidth,
            height: 19
        )
        let statsX = (directoryLabel.frame.width > 0 ? directoryLabel.frame.maxX : title.frame.maxX) + statsSpacing
        stats.frame = NSRect(x: statsX, y: headerCenterY(19), width: statsWidth, height: 19)
        var x = controlsX
        for (button, width) in zip([wholeFileButton, primaryButton, discardButton, reviewButton, menuButton] as [NSButton], widths) {
            button.frame = NSRect(x: x, y: headerCenterY(ReviewControlMetrics.height), width: width, height: ReviewControlMetrics.height)
            if width > 0 { x += width + ReviewControlMetrics.spacing }
        }
    }

    static let leadingGapHeight: CGFloat = 0

    private func headerCenterY(_ height: CGFloat) -> CGFloat {
        max(0, (bounds.height - height) / 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let background = isFocused || isHovered ? AgentGitPalette.fileHeaderFocused : AgentGitPalette.fileHeader
        background.setFill()
        dirtyRect.fill()
        if isFocused {
            AgentGitPalette.focusIndicator.setFill()
            NSRect(x: 0, y: 6, width: 2, height: bounds.height - 12).fill()
        }
        // 相邻两个文件标题之间用顶部一条细线分开，展开后标题行下面直接接代码。
        AgentGitPalette.reviewDivider.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
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
        self.reviewHandler = reviewHandler ?? self.reviewHandler
        self.wholeFileHandler = wholeFileHandler ?? self.wholeFileHandler
        self.actionHandler = actionHandler ?? self.actionHandler
        self.menuHandler = menuHandler ?? self.menuHandler
        let nextHeaderKey = RenderedHeaderKey(
            id: file.id,
            path: file.path,
            originalPath: file.originalPath,
            status: file.status,
            statusLabel: file.statusLabel,
            isExpanded: file.isExpanded,
            isFocused: file.isFocused,
            isReviewed: file.isReviewed,
            showsWholeFile: file.showsWholeFile,
            isLoadingWholeFile: file.isLoadingWholeFile,
            canToggleWholeFile: file.canToggleWholeFile,
            canApplyPrimaryAction: file.canApplyPrimaryAction,
            canDiscard: file.canDiscard,
            isMutationEnabled: file.isMutationEnabled,
            mutationSnapshotID: file.mutationSnapshotID,
            mutationMode: file.mutationMode,
            hasDiff: file.diff != nil,
            addedLineCount: file.diff?.addedLineCount,
            deletedLineCount: file.diff?.deletedLineCount
        )
        if renderedHeaderKey == nextHeaderKey,
           globalMutationActionsEnabled == mutationActionsEnabled {
            return
        }
        renderedHeaderKey = nextHeaderKey
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
        canToggleWholeFile = file.canToggleWholeFile
        canApplyPrimaryAction = file.mutationMode != nil && file.canApplyPrimaryAction
        canDiscard = file.mutationMode == .working && file.canDiscard
        mutationMode = file.mutationMode
        fileMutationActionsEnabled = file.isMutationEnabled
        globalMutationActionsEnabled = mutationActionsEnabled
        chevron.setExpanded(file.isExpanded)
        updateStatusPresentation(
            for: file.status,
            statusLabel: file.statusLabel
        )
        let titleAttributed = Self.titleText(
            path: file.path,
            originalPath: file.originalPath
        )
        title.attributedStringValue = titleAttributed
        let titleCTLine = CTLineCreateWithAttributedString(titleAttributed)
        cachedTitleWidth = ceil(CGFloat(CTLineGetTypographicBounds(titleCTLine, nil, nil, nil))) + 4
        let directory = (file.path as NSString).deletingLastPathComponent
        let originalDirectory = file.originalPath.map { ($0 as NSString).deletingLastPathComponent }
        let directoryText = originalDirectory.flatMap {
            $0 == directory ? nil : "\($0.isEmpty ? "Repository root" : $0)  →  \(directory.isEmpty ? "Repository root" : directory)"
        } ?? directory
        directoryLabel.stringValue = directoryText
        directoryLabel.isHidden = directoryText.isEmpty
        if directoryText.isEmpty {
            cachedDirectoryWidth = 0
        } else {
            let cfDir = directoryText as CFString
            let attr = CFAttributedStringCreateMutable(kCFAllocatorDefault, CFStringGetLength(cfDir))!
            CFAttributedStringBeginEditing(attr)
            CFAttributedStringReplaceString(attr, CFRange(location: 0, length: 0), cfDir)
            CFAttributedStringSetAttribute(attr, CFRange(location: 0, length: CFStringGetLength(cfDir)), kCTFontAttributeName, Self.directoryCTFont)
            CFAttributedStringEndEditing(attr)
            let dirCTLine = CTLineCreateWithAttributedString(attr)
            cachedDirectoryWidth = ceil(CGFloat(CTLineGetTypographicBounds(dirCTLine, nil, nil, nil))) + 4
        }
        let pathToolTip = file.originalPath.map { "\($0) → \(file.path)" } ?? file.path
        title.diffHoverToolTip = pathToolTip
        title.setAccessibilityLabel(pathToolTip)
        stats.update(diff: file.diff)
        let wholeFileTitle: String
        if file.isLoadingWholeFile {
            wholeFileTitle = "Loading Whole File…"
        } else if file.showsWholeFile {
            wholeFileTitle = "Show Only Modified Hunks"
        } else {
            wholeFileTitle = "Show Entire File"
        }
        wholeFileButton.title = file.isLoadingWholeFile ? "Loading…" : file.showsWholeFile ? "Changes only" : "Whole file"
        wholeFileButton.image = Self.wholeFileDocImage
        wholeFileButton.state = file.showsWholeFile ? .on : .off
        wholeFileButton.isHidden = !canToggleWholeFile
        wholeFileButton.isEnabled = !file.isLoadingWholeFile
        wholeFileButton.contentTintColor = file.showsWholeFile
            ? AgentGitPalette.activeControl
            : .tertiaryLabelColor
        wholeFileButton.diffHoverToolTip = wholeFileTitle
        wholeFileButton.setAccessibilityLabel(wholeFileTitle)
        reviewButton.image = (file.isReviewed ? ReviewIcon.reviewed : ReviewIcon.review).image
        reviewButton.state = file.isReviewed ? .on : .off
        reviewButton.contentTintColor = file.isReviewed ? AgentGitPalette.statusAdded : AgentGitPalette.sidebarMetadata
        reviewButton.isHidden = false
        reviewButton.isEnabled = canReview
        let reviewTitle = file.isReviewed ? "Mark as Unreviewed" : "Mark as Reviewed"
        reviewButton.diffHoverToolTip = reviewTitle
        reviewButton.setAccessibilityLabel(reviewTitle)
        primaryButton.title = file.mutationMode?.fileActionTitle ?? ""
        primaryButton.setAccessibilityLabel("\(primaryButton.title) File")
        primaryButton.image = (file.mutationMode == .staged ? ReviewIcon.unstage : ReviewIcon.stage).actionImage
        primaryButton.imagePosition = .imageOnly
        discardButton.imagePosition = isConfirmingDiscard ? .noImage : .imageOnly
        primaryButton.diffHoverToolTip = file.status == .conflicted
            ? "Stage the file after resolving its conflict markers"
            : primaryButton.title
        updateMutationAvailability()
        updateActionVisibility()
        diffHoverToolTip = file.status == .conflicted
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
        button.font = AgentGitTypography.interface(
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
        reviewButton.imageScaling = .scaleProportionallyDown
    }

    private func configureMenuButton() {
        menuButton.identifier = NSUserInterfaceItemIdentifier("file-actions-menu")
        menuButton.target = self
        menuButton.action = #selector(showFileActions)
        menuButton.bezelStyle = .inline
        menuButton.isBordered = false
        menuButton.imagePosition = .imageOnly
        menuButton.imageScaling = .scaleProportionallyDown
        menuButton.image = ReviewIcon.more.image
        menuButton.contentTintColor = .secondaryLabelColor
        menuButton.diffHoverToolTip = "File Actions"
        menuButton.setAccessibilityLabel("File Actions")
    }

    private func configureStatusIcon() {
        statusIcon.identifier = NSUserInterfaceItemIdentifier("file-status-icon")
        statusIcon.imageScaling = .scaleNone
        statusIcon.isHidden = true
        statusText.identifier = NSUserInterfaceItemIdentifier("file-status-label")
        statusText.isHidden = true
    }

    /// 文件名前统一放 `</>` 代码图标；修改的文件用灰色，新增、删除、改名等状态用对应颜色，
    /// 冲突文件换成警告图标。
    private func updateStatusPresentation(
        for status: DiffStackStatus,
        statusLabel: String
    ) {
        statusColor = Self.color(for: status)
        let label: String = switch status {
        case .conflicted: "Conflicted File"
        case .added: "Added File"
        case .untracked: "Untracked File"
        case .deleted: "Deleted File"
        case .renamed: "Renamed File"
        case .modified: "Modified File"
        }
        statusIcon.isHidden = false
        statusText.isHidden = true
        statusText.stringValue = statusLabel
        statusText.setAccessibilityLabel(nil)
        statusIcon.image = status == .conflicted ? Self.conflictStatusImage : Self.codeStatusImage
        statusIcon.contentTintColor = status == .modified ? AgentGitPalette.reviewTertiaryText : Self.color(for: status)
        statusIcon.diffHoverToolTip = label
        statusIcon.setAccessibilityLabel(label)
    }

    private func configureWholeFileButton() {
        wholeFileButton.identifier = NSUserInterfaceItemIdentifier("whole-file-toggle")
        wholeFileButton.target = self
        wholeFileButton.action = #selector(toggleWholeFile)
        wholeFileButton.bezelStyle = .inline
        wholeFileButton.isBordered = false
        wholeFileButton.font = ReviewWorkspaceStyle.nativeFont(12)
        wholeFileButton.imagePosition = .imageLeft
        wholeFileButton.imageScaling = .scaleProportionallyDown
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
        discardButton.imagePosition = .noImage
        discardButton.contentTintColor = .systemRed
        discardButton.diffHoverToolTip = "Confirm discard; a recovery copy will be saved in Trash"
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
        discardButton.imagePosition = .imageOnly
        discardButton.contentTintColor = .secondaryLabelColor
        discardButton.diffHoverToolTip = "Discard file changes; saves a recovery copy in Trash"
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
        return NSAttributedString(string: displayed, attributes: [
            .paragraphStyle: titleParagraphStyle,
            .font: ReviewWorkspaceStyle.nativeFont(ReviewWorkspaceStyle.fileTitleSize),
            .foregroundColor: AgentGitPalette.reviewPrimaryText
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
        font: AgentGitTypography.interface(ofSize: 11, weight: .semibold),
        textColor: .secondaryLabelColor,
        alignment: .left,
        selectable: false
    )
    private let metadataLabel = DiffTextField(
        font: AgentGitTypography.interface(ofSize: 10, weight: .regular),
        textColor: .tertiaryLabelColor,
        alignment: .right,
        selectable: false
    )
    private let canvas = DiffImageCanvasView()
    private let placeholderLabel = DiffTextField(
        font: AgentGitTypography.interface(ofSize: 12, weight: .medium),
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
            diffHoverToolTip = emptyMessage
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
        diffHoverToolTip = metadataLabel.stringValue
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
            diffHoverToolTip = currentEmptyMessage
            canvas.updateAccessibility(
                label: "\(paneTitle) image",
                value: currentEmptyMessage
            )
        } else {
            placeholderLabel.stringValue = "Preview paused in background"
            diffHoverToolTip = placeholderLabel.stringValue
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
        diffHoverToolTip = metadataLabel.stringValue
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

private final class DiffFileFooterCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("diff-file-footer")

    private let button = ReviewGlyphButton(title: "", target: nil, action: nil)
    private var fileID = ""
    private var collapseHandler: ((String) -> Void)?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        canDrawSubviewsIntoLayer = true
        button.identifier = NSUserInterfaceItemIdentifier("collapse-file-footer")
        button.target = self
        button.action = #selector(collapseFile)
        button.imagePosition = .imageOnly
        button.image = ReviewIcon.previous.actionImage
        button.contentTintColor = AgentGitPalette.reviewSecondaryText
        button.diffHoverToolTip = "Collapse file above"
        button.setAccessibilityLabel("Collapse file above")
        addSubview(button)
    }

    required init?(coder: NSCoder) { nil }

    override func prepareForReuse() {
        super.prepareForReuse()
        button.setPointerHovered(false)
    }

    override func layout() {
        super.layout()
        button.frame = NSRect(x: 6, y: 1, width: ReviewControlMetrics.height, height: ReviewControlMetrics.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        AgentGitPalette.codeBackground.setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
    }

    func update(fileID: String, collapseHandler: @escaping (String) -> Void) {
        self.fileID = fileID
        self.collapseHandler = collapseHandler
    }

    @objc private func collapseFile() {
        collapseHandler?(fileID)
    }
}

private final class DiffFileContextToggleCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("diff-file-context-toggle")

    private static let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
    @MainActor private static let loadingImage = NSImage(
        systemSymbolName: "ellipsis",
        accessibilityDescription: nil
    )?.withSymbolConfiguration(symbolConfiguration)
    @MainActor private static let compressImage = NSImage(
        systemSymbolName: "rectangle.compress.vertical",
        accessibilityDescription: nil
    )?.withSymbolConfiguration(symbolConfiguration)
    @MainActor private static let expandImage = NSImage(
        systemSymbolName: "rectangle.expand.vertical",
        accessibilityDescription: nil
    )?.withSymbolConfiguration(symbolConfiguration)

    private let button = NSButton(title: "", target: nil, action: nil)
    private var fileID = ""
    private var renderedShowsWholeFile: Bool?
    private var renderedIsLoading: Bool?
    private var toggleHandler: ((String) -> Void)?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        canDrawSubviewsIntoLayer = true
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
        AgentGitPalette.reviewDivider.setFill()
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
        guard renderedShowsWholeFile != showsWholeFile || renderedIsLoading != isLoading else {
            return
        }
        renderedShowsWholeFile = showsWholeFile
        renderedIsLoading = isLoading
        let title: String
        let image: NSImage?
        if isLoading {
            title = "Loading entire file…"
            image = Self.loadingImage
        } else if showsWholeFile {
            title = "Show only modified hunks"
            image = Self.compressImage
        } else {
            title = "Show entire file"
            image = Self.expandImage
        }
        button.image = image
        button.isEnabled = !isLoading
        button.diffHoverToolTip = title
        button.setAccessibilityLabel(title)
        needsDisplay = true
    }

    @objc private func toggleWholeFile() {
        toggleHandler?(fileID)
    }
}

/// 文件末尾被折叠的上下文，和 hunk 之间的分隔行同样只显示一行灰字，点一下展开。
private final class DiffContextEdgeCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("diff-context-edge")

    private let button = ReviewGlyphButton(title: "", target: nil, action: nil)
    private var progressIndicator: NSProgressIndicator?
    private var fileID = ""
    private var gap: DiffStackContextGap?
    private var renderedIsLoading: Bool?
    private var cachedButtonWidth: CGFloat = ReviewControlMetrics.height
    private var expandHandler: ((String, DiffStackContextGap) -> Void)?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        canDrawSubviewsIntoLayer = true
        button.identifier = NSUserInterfaceItemIdentifier("hunk-context-expand")
        button.target = self
        button.action = #selector(expand)
        button.bezelStyle = .inline
        button.isBordered = false
        button.imagePosition = .noImage
        button.font = DiffHunkCellView.gapFont
        button.contentTintColor = AgentGitPalette.reviewSecondaryText
        addSubview(button)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        button.setPointerHovered(false)
    }

    override func layout() {
        super.layout()
        let height = min(ReviewControlMetrics.height, bounds.height)
        button.frame = NSRect(x: 6, y: max(0, (bounds.height - height) / 2), width: cachedButtonWidth, height: height)
        progressIndicator?.frame = NSRect(
            x: button.frame.maxX,
            y: max(0, (bounds.height - 12) / 2),
            width: 12,
            height: 12
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        AgentGitPalette.codeBackground.setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
    }

    func update(
        gap: DiffStackContextGap,
        fileID: String,
        isLoading: Bool,
        expandHandler: @escaping (String, DiffStackContextGap) -> Void
    ) {
        self.fileID = fileID
        self.expandHandler = expandHandler
        guard self.gap != gap || renderedIsLoading != isLoading else {
            return
        }
        self.gap = gap
        renderedIsLoading = isLoading
        let shownLineCount = min(20, gap.hiddenLineCount)
        let expandTitle = gap.hiddenLineCount == shownLineCount
            ? "Show \(shownLineCount) hidden lines"
            : "Show \(shownLineCount) of \(gap.hiddenLineCount) hidden lines"
        if isLoading {
            button.title = "Loading hidden lines…"
            let indicator = progressIndicator ?? {
                let spinner = NSProgressIndicator()
                spinner.style = .spinning
                spinner.controlSize = .small
                spinner.isDisplayedWhenStopped = false
                addSubview(spinner)
                progressIndicator = spinner
                return spinner
            }()
            indicator.startAnimation(nil)
        } else {
            button.title = unmodifiedLinesTitle(gap.hiddenLineCount)
            progressIndicator?.stopAnimation(nil)
        }
        cachedButtonWidth = ReviewButtonCell.preferredWidth(
            title: button.title,
            image: nil,
            font: DiffHunkCellView.gapFont
        )
        button.isEnabled = !isLoading
        let buttonToolTip = isLoading ? button.title : expandTitle
        button.diffHoverToolTip = buttonToolTip
        button.setAccessibilityLabel(buttonToolTip)
        needsLayout = true
        needsDisplay = true
    }

    @objc private func expand() {
        guard let gap else {
            return
        }
        expandHandler?(fileID, gap)
    }
}

func unmodifiedLinesTitle(_ count: Int) -> String {
    count == 1 ? "1 unmodified line" : "\(count) unmodified lines"
}

private final class DiffNoteCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("diff-note")

    private let label = DiffTextField(
        font: AgentGitTypography.interface(ofSize: 11, weight: .regular),
        textColor: .secondaryLabelColor,
        alignment: .left,
        selectable: false
    )

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        canDrawSubviewsIntoLayer = true
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 48, y: 8, width: max(0, bounds.width - 60), height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        AgentGitPalette.codeBackground.setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
    }

    func update(text: String) {
        guard label.stringValue != text else { return }
        label.stringValue = text
        needsDisplay = true
    }
}

/// hunk 之间的分隔行：左侧一行灰字「N unmodified lines」，点一下展开被折叠的上下文；
/// 后面跟着 hunk 所在的函数名，增删操作在鼠标移上来时出现在右侧。
private final class DiffHunkCellView: NSTableCellView, DiffRowSelectionCell, DiffHoverCellTarget {
    /// 带折叠上下文时行高放大，上下各留出约一行的空白。
    nonisolated static let gapHeight: CGFloat = 44
    @MainActor static let gapFont = ReviewWorkspaceStyle.nativeFont(13)
    @MainActor private static let menuEllipsisImage = NSImage(
        systemSymbolName: "ellipsis",
        accessibilityDescription: nil
    )?.withSymbolConfiguration(
        NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
    )

    private struct RenderedHunkKey: Equatable {
        let anchorID: String
        let gapID: String?
        let hiddenLineCount: Int?
        let isLoadingContextGap: Bool
        let title: String
        let location: String
        let rawHeader: String
        let layout: DiffLayoutMode
        let fileID: String
        let lineIDCount: Int
        let historyStartLine: Int
        let historyEndLine: Int
        let mutationMode: DiffStackMutationMode?
        let isMutationEnabled: Bool
        let mutationSnapshotID: DiffReviewSnapshotID?
    }

    private static let discardConfirmationDuration: TimeInterval = 3
    static let identifier = NSUserInterfaceItemIdentifier("diff-hunk")

    private let unifiedTitle = DiffTextField(
        font: ReviewWorkspaceStyle.nativeFont(12),
        textColor: AgentGitPalette.reviewTertiaryText,
        alignment: .left,
        selectable: false
    )
    private let location = DiffTextField(
        font: .monospacedSystemFont(ofSize: 10.5, weight: .regular),
        textColor: .tertiaryLabelColor,
        alignment: .right,
        selectable: false
    )
    /// hunk 上方那段被折叠的上下文的展开入口。Sublime Merge 把它做在标题条左端，
    /// 不额外占一行，这里跟着对齐。
    private let contextExpandButton = ReviewGlyphButton(title: "", target: nil, action: nil)
    private var contextProgress: NSProgressIndicator?
    private let historyButton = ReviewActionButton(
        title: "",
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
    private var canShowHistory = false
    private var isHovered = false
    private var layoutMode: DiffLayoutMode = .unified
    private var contextGap: DiffStackContextGap?
    private var isLoadingContextGap = false
    private var cachedContextExpandWidth: CGFloat = 0
    private var contextExpandHandler: ((String, DiffStackContextGap) -> Void)?
    private var historyHandler: ((String, Int, Int) -> Void)?
    private var actionHandler: ((String, Set<GitDiffLine.ID>, GitPendingSelectionAction) -> Void)?
    private var renderedHunkKey: RenderedHunkKey?
    private var isRowSelected = false

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        canDrawSubviewsIntoLayer = true
        unifiedTitle.identifier = NSUserInterfaceItemIdentifier("hunk-title-unified")
        addSubview(unifiedTitle)
        location.identifier = NSUserInterfaceItemIdentifier("hunk-location")
        addSubview(location)
        contextExpandButton.identifier = NSUserInterfaceItemIdentifier("hunk-context-expand")
        contextExpandButton.target = self
        contextExpandButton.action = #selector(expandContextGap)
        contextExpandButton.bezelStyle = .inline
        contextExpandButton.isBordered = false
        contextExpandButton.imagePosition = .noImage
        contextExpandButton.font = Self.gapFont
        contextExpandButton.contentTintColor = AgentGitPalette.reviewSecondaryText
        addSubview(contextExpandButton)
        addSubview(historyButton)
        addSubview(menuButton)
        addSubview(primaryButton)
        addSubview(discardButton)
        historyButton.identifier = NSUserInterfaceItemIdentifier("hunk-history")
        historyButton.image = ReviewIcon.history.actionImage
        historyButton.imagePosition = .imageOnly
        historyButton.diffHoverToolTip = "Show history for these lines"
        historyButton.setAccessibilityLabel("Hunk History")
        historyButton.setAccessibilityHelp(
            "Filter commit history to the lines in this hunk"
        )
        configure(historyButton, action: #selector(showHistory))
        menuButton.identifier = NSUserInterfaceItemIdentifier("hunk-actions-menu")
        menuButton.imagePosition = .imageOnly
        menuButton.imageScaling = .scaleProportionallyDown
        menuButton.image = Self.menuEllipsisImage
        menuButton.contentTintColor = .secondaryLabelColor
        menuButton.setAccessibilityLabel("Hunk Actions")
        menuButton.setAccessibilityHelp("Show actions for this hunk")
        configure(menuButton, action: #selector(showHunkMenu))
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

    override func prepareForReuse() {
        super.prepareForReuse()
        setPointerHovered(false)
        contextExpandButton.setPointerHovered(false)
        historyButton.setPointerHovered(false)
        menuButton.setPointerHovered(false)
        primaryButton.setPointerHovered(false)
        discardButton.setPointerHovered(false)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            isHovered = false
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
        let primaryWidth = ReviewControlMetrics.height
        let discardWidth = discardButton.discardWidth
        let spacing = ReviewControlMetrics.spacing
        let actionsWidth = primaryWidth + discardWidth + spacing
        let historyWidth = ReviewControlMetrics.height
        let menuWidth = ReviewControlMetrics.height
        let historySpacing = ReviewControlMetrics.spacing
        let actionSpacing = ReviewControlMetrics.spacing
        let expandWidth = contextExpandButton.isHidden ? 0 : cachedContextExpandWidth
        let menuX = bounds.width - menuWidth - ReviewControlMetrics.trailingInset
        let historyX = menuX - historyWidth - historySpacing
        let actionX = historyX - actionsWidth - actionSpacing
        let actionHeight = min(ReviewControlMetrics.height, bounds.height)
        let actionY = max(0, (bounds.height - actionHeight) / 2)
        location.isHidden = isHovered || isConfirmingDiscard
            || !primaryButton.isHidden || !historyButton.isHidden || !menuButton.isHidden
        location.frame = NSRect(x: max(0, bounds.width - 154), y: (bounds.height - 16) / 2, width: 140, height: 16)
        // 按钮左右各留 8pt 内边距，文字起点落在 14pt，和文件标题的箭头对齐。
        contextExpandButton.frame = NSRect(
            x: 6,
            y: actionY,
            width: expandWidth,
            height: actionHeight
        )
        let progressMaxX = contextExpandButton.frame.maxX + 12
        contextProgress?.frame = NSRect(
            x: contextExpandButton.frame.maxX,
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
            y: actionY,
            width: historyWidth,
            height: actionHeight
        )
        menuButton.frame = NSRect(
            x: menuX,
            y: actionY,
            width: menuWidth,
            height: actionHeight
        )
        let titleX = contextExpandButton.isHidden
            ? 14
            : progressMaxX + (isLoadingContextGap ? 8 : -6)
        unifiedTitle.frame = NSRect(
            x: titleX,
            y: max(0, (bounds.height - 16) / 2),
            width: max(0, (location.isHidden ? actionX : min(actionX, location.frame.minX)) - titleX - 8),
            height: 16
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        AgentGitPalette.hunkHeader.setFill()
        dirtyRect.fill()
        if isRowSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
            dirtyRect.fill()
        }
        if layoutMode == .sideBySide {
            AgentGitPalette.splitPaneDivider.setFill()
            NSRect(x: floor(bounds.width / 2), y: 0, width: 1, height: bounds.height).fill()
        }
        super.draw(dirtyRect)
    }

    func updateRowSelection(_ selected: Bool) {
        guard isRowSelected != selected else {
            return
        }
        isRowSelected = selected
        needsDisplay = true
    }

    func setPointerHovered(_ hovered: Bool) {
        guard isHovered != hovered else {
            return
        }
        isHovered = hovered
        updateHoverControls()
        needsDisplay = true
    }

    func update(
        hunk: DiffStackHunkRow,
        mutationActionsEnabled: Bool = true,
        isLoadingContextGap: Bool = false,
        contextExpandHandler: ((String, DiffStackContextGap) -> Void)? = nil,
        historyHandler: ((String, Int, Int) -> Void)?,
        actionHandler: ((String, Set<GitDiffLine.ID>, GitPendingSelectionAction) -> Void)?
    ) {
        self.contextExpandHandler = contextExpandHandler
        self.historyHandler = historyHandler
        self.actionHandler = actionHandler
        lineIDs = hunk.lineIDs

        let nextKey = RenderedHunkKey(
            anchorID: hunk.anchorID,
            gapID: hunk.contextGap?.id,
            hiddenLineCount: hunk.contextGap?.hiddenLineCount,
            isLoadingContextGap: isLoadingContextGap,
            title: hunk.title,
            location: hunk.location,
            rawHeader: hunk.rawHeader,
            layout: hunk.layout,
            fileID: hunk.fileID,
            lineIDCount: hunk.lineIDs.count,
            historyStartLine: hunk.historyStartLine,
            historyEndLine: hunk.historyEndLine,
            mutationMode: hunk.mutationMode,
            isMutationEnabled: hunk.isMutationEnabled,
            mutationSnapshotID: hunk.mutationSnapshotID
        )
        if renderedHunkKey == nextKey {
            setMutationActionsEnabled(mutationActionsEnabled)
            return
        }
        renderedHunkKey = nextKey

        contextGap = hunk.contextGap
        self.isLoadingContextGap = isLoadingContextGap
        updateContextExpansion()
        if fileID != hunk.fileID {
            isHovered = false
        }
        let confirmationID = "\(hunk.anchorID):"
            + "\(hunk.mutationSnapshotID?.rawValue ?? 0):"
            + "\(hunk.lineIDs.count)"
        if discardConfirmationID != confirmationID || hunk.mutationMode != .working {
            resetDiscardConfirmation()
        }
        discardConfirmationID = confirmationID
        // 左右两栏的 section 是同一个，画两遍等于让同一句话在一行里出现两次。
        unifiedTitle.stringValue = hunk.title
        location.stringValue = hunk.location
        unifiedTitle.diffHoverToolTip = hunk.rawHeader
        layoutMode = hunk.layout
        fileID = hunk.fileID
        historyStartLine = hunk.historyStartLine
        historyEndLine = hunk.historyEndLine
        rawHeader = hunk.rawHeader
        mutationMode = hunk.mutationMode
        hunkMutationActionsEnabled = hunk.isMutationEnabled
        globalMutationActionsEnabled = mutationActionsEnabled
        canShowHistory = hunk.mutationMode == nil
        primaryButton.title = hunk.mutationMode?.hunkActionTitle ?? ""
        primaryButton.setAccessibilityLabel(primaryButton.title)
        primaryButton.diffHoverToolTip = primaryButton.title
        primaryButton.image = (hunk.mutationMode == .staged ? ReviewIcon.unstage : ReviewIcon.stage).actionImage
        primaryButton.imagePosition = .imageOnly
        discardButton.imagePosition = isConfirmingDiscard ? .noImage : .imageOnly
        updateMutationAvailability()
        updateHoverControls()
        diffHoverToolTip = "\(hunk.rawHeader)\nOption-Down: Next Hunk  ·  Option-Up: Previous Hunk"
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
        button.font = AgentGitTypography.interface(
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
            cachedContextExpandWidth = 0
            contextProgress?.stopAnimation(nil)
            return
        }
        // 加载时文字换成进度说明，按钮只禁用不移动，转圈跟在文字后面。
        contextExpandButton.isHidden = false
        contextExpandButton.isEnabled = !isLoadingContextGap
        contextExpandButton.title = isLoadingContextGap
            ? "Loading hidden lines…"
            : unmodifiedLinesTitle(contextGap.hiddenLineCount)
        cachedContextExpandWidth = ReviewButtonCell.preferredWidth(
            title: contextExpandButton.title,
            image: nil,
            font: Self.gapFont
        )
        if isLoadingContextGap {
            let indicator = contextProgress ?? {
                let spinner = NSProgressIndicator()
                spinner.style = .spinning
                spinner.controlSize = .small
                spinner.isDisplayedWhenStopped = false
                spinner.setAccessibilityLabel("Loading hidden lines…")
                addSubview(spinner)
                contextProgress = spinner
                return spinner
            }()
            indicator.startAnimation(nil)
        } else {
            contextProgress?.stopAnimation(nil)
        }
        let shownLineCount = min(20, contextGap.hiddenLineCount)
        let title = isLoadingContextGap
            ? "Loading hidden lines…"
            : (contextGap.hiddenLineCount == shownLineCount
                ? "Show \(shownLineCount) hidden lines"
                : "Show \(shownLineCount) of \(contextGap.hiddenLineCount) hidden lines")
        contextExpandButton.diffHoverToolTip = title
        contextExpandButton.setAccessibilityLabel(title)
        needsLayout = true
    }

    @objc private func expandContextGap() {
        guard let contextGap, !isLoadingContextGap else {
            return
        }
        contextExpandHandler?(fileID, contextGap)
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
        discardButton.imagePosition = .noImage
        discardButton.contentTintColor = .systemRed
        discardButton.diffHoverToolTip = "Confirm discard hunk; a recovery copy will be saved in Trash"
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
        discardButton.imagePosition = .imageOnly
        discardButton.contentTintColor = .secondaryLabelColor
        discardButton.diffHoverToolTip = "Discard hunk changes; saves a recovery copy in Trash"
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
        historyButton.isHidden = !canShowHistory
        menuButton.isHidden = !canShowHistory
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

enum DiffAppearanceVariant: UInt8, Hashable, CaseIterable {
    case aqua
    case darkAqua
    case highContrastAqua
    case highContrastDarkAqua

    private static let matchNames: [NSAppearance.Name] = [
        .accessibilityHighContrastDarkAqua,
        .accessibilityHighContrastAqua,
        .darkAqua,
        .aqua
    ]

    @MainActor
    init(appearance: NSAppearance?) {
        let target = appearance ?? NSApp?.effectiveAppearance
        switch target?.bestMatch(from: Self.matchNames) {
        case .accessibilityHighContrastDarkAqua:
            self = .highContrastDarkAqua
        case .accessibilityHighContrastAqua:
            self = .highContrastAqua
        case .darkAqua:
            self = .darkAqua
        default:
            self = .aqua
        }
    }

    var nsAppearance: NSAppearance? {
        let name: NSAppearance.Name = switch self {
        case .aqua: .aqua
        case .darkAqua: .darkAqua
        case .highContrastAqua: .accessibilityHighContrastAqua
        case .highContrastDarkAqua: .accessibilityHighContrastDarkAqua
        }
        return NSAppearance(named: name)
    }

    func resolveCGColor(_ color: NSColor) -> CGColor {
        guard let nsAppearance else {
            return color.cgColor
        }
        var resolved = color.cgColor
        nsAppearance.performAsCurrentDrawingAppearance {
            resolved = color.cgColor
        }
        return resolved
    }
}

@MainActor
private enum DiffCodeMetrics {
    static let ctFont: CTFont = AgentGitTypography.code as CTFont
    static let ctEmphasizedFont: CTFont = AgentGitTypography.codeEmphasized as CTFont
    static let ascent: CGFloat = CTFontGetAscent(ctFont)
    static let descent: CGFloat = CTFontGetDescent(ctFont)

    static func baselineY(in rowHeight: CGFloat) -> CGFloat {
        round(((rowHeight + ascent - descent) * 0.5) * 2) * 0.5
    }
}

private func drawFlippedCTLine(_ line: CTLine, at origin: CGPoint, in context: CGContext) {
    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    context.textPosition = origin
    CTLineDraw(line, context)
}

@MainActor
private enum DiffGutterTextCache {
    enum Tone: UInt8, Hashable {
        case normal
        case addition
        case deletion
        case metadata

        var color: NSColor {
            switch self {
            case .normal: AgentGitPalette.codeLineNumber
            case .addition: AgentGitPalette.additionText
            case .deletion: AgentGitPalette.deletionText
            case .metadata: .secondaryLabelColor
            }
        }
    }

    struct Entry {
        let ctLine: CTLine
        let width: CGFloat
    }

    private struct Key: Hashable {
        let text: String
        let tone: Tone
        let appearance: DiffAppearanceVariant
    }

    private static let generationLimit = 2_048
    private static var currentGeneration: [Key: Entry] = [:]
    private static var previousGeneration: [Key: Entry] = [:]

    static func entry(
        text: String,
        tone: Tone,
        appearance: DiffAppearanceVariant
    ) -> Entry {
        let key = Key(text: text, tone: tone, appearance: appearance)
        if let cached = currentGeneration[key] {
            return cached
        }
        if let cached = previousGeneration[key] {
            promote(cached, for: key)
            return cached
        }
        let cfText = text as CFString
        let length = CFStringGetLength(cfText)
        let attr = CFAttributedStringCreateMutable(kCFAllocatorDefault, length)!
        CFAttributedStringBeginEditing(attr)
        CFAttributedStringReplaceString(attr, CFRange(location: 0, length: 0), cfText)
        let fullRange = CFRange(location: 0, length: length)
        CFAttributedStringSetAttribute(attr, fullRange, kCTFontAttributeName, DiffCodeMetrics.ctFont)
        CFAttributedStringSetAttribute(
            attr,
            fullRange,
            kCTForegroundColorAttributeName,
            appearance.resolveCGColor(tone.color)
        )
        CFAttributedStringEndEditing(attr)
        let ctLine = CTLineCreateWithAttributedString(attr)
        let width = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
        let built = Entry(ctLine: ctLine, width: width)
        promote(built, for: key)
        return built
    }

    private static func promote(_ value: Entry, for key: Key) {
        if currentGeneration.count >= generationLimit {
            previousGeneration = currentGeneration
            currentGeneration = [:]
            currentGeneration.reserveCapacity(256)
        }
        currentGeneration[key] = value
    }
}

private final class DiffLineCellView: NSTableCellView, DiffCodeViewport, DiffCodeSelectionCell, DiffRowSelectionCell {
    static let identifier = NSUserInterfaceItemIdentifier("diff-line")

    var codeTextViewsByColumn: [DiffCodeColumn: DiffSelectableTextView] {
        [.unified: content]
    }

    /// 统一视图只留一列行号：新增和上下文行显示新行号，删除行显示旧行号。
    /// 最左是增删竖条，接着是右对齐的行号和 +/- 符号，代码从 `codeLeading` 开始。
    private static let lineNumberMaxX: CGFloat = 42
    private static let markerMinX: CGFloat = 46
    private static let markerWidth: CGFloat = 12
    nonisolated static let codeLeading: CGFloat = 64

    private let content = DiffSelectableTextView(
        font: AgentGitTypography.code,
        textColor: AgentGitPalette.codeText
    )
    private var kind: GitDiffLineKind = .context
    private var lineNumberText = ""
    private var lineNumberTone: DiffGutterTextCache.Tone = .normal
    private var markerSymbol = ""
    private var markerTone: DiffGutterTextCache.Tone = .normal
    private var renderedLine: GitDiffLine?
    private var renderedLanguage: GitSyntaxLanguage?
    private var codeContentWidth: CGFloat = 0
    private var isRowSelected = false

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsFormat = .RGBA8Uint
        layer?.isOpaque = true
        canDrawSubviewsIntoLayer = true
        content.wantsLayer = false
        content.clipsToBounds = false
        content.identifier = NSUserInterfaceItemIdentifier("diff-unified-code-content")
        addSubview(content)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        let viewportWidth = max(0, bounds.width - Self.codeLeading - 8)
        content.frame = NSRect(
            x: Self.codeLeading,
            y: 0,
            width: viewportWidth,
            height: bounds.height
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        let appearance = DiffAppearanceVariant(appearance: effectiveAppearance)
        context.setFillColor(appearance.resolveCGColor(backgroundColor))
        context.fill(dirtyRect)

        if let barColor = diffChangeBarColor(for: kind) {
            let barRect = NSRect(x: 0, y: 0, width: AgentGitPalette.diffChangeBarWidth, height: bounds.height)
            if barRect.intersects(dirtyRect) {
                context.setFillColor(appearance.resolveCGColor(barColor))
                context.fill(barRect)
            }
        }
        if isRowSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
            dirtyRect.fill()
        }

        // 行号列和 +/- 标记只在左槽落在脏区内时重绘。
        if dirtyRect.minX < Self.codeLeading {
            let baselineY = DiffCodeMetrics.baselineY(in: bounds.height)
            if !lineNumberText.isEmpty {
                let entry = DiffGutterTextCache.entry(
                    text: lineNumberText,
                    tone: lineNumberTone,
                    appearance: appearance
                )
                drawFlippedCTLine(
                    entry.ctLine,
                    at: CGPoint(x: Self.lineNumberMaxX - entry.width, y: baselineY),
                    in: context
                )
            }
            if !markerSymbol.isEmpty {
                let entry = DiffGutterTextCache.entry(
                    text: markerSymbol,
                    tone: markerTone,
                    appearance: appearance
                )
                let markerX = Self.markerMinX + (Self.markerWidth - entry.width) * 0.5
                drawFlippedCTLine(
                    entry.ctLine,
                    at: CGPoint(x: markerX, y: baselineY),
                    in: context
                )
            }
        }
    }

    func updateRowSelection(_ selected: Bool) {
        guard isRowSelected != selected else { return }
        isRowSelected = selected
        content.setRowSelected(selected)
        needsDisplay = true
    }

    func update(line: GitDiffLine, language: GitSyntaxLanguage) {
        guard renderedLine != line || renderedLanguage != language else {
            content.clearSelectionIfNeeded()
            return
        }
        renderedLine = line
        renderedLanguage = language
        kind = line.kind
        let displayedLineNumber = line.kind == .deletion
            ? line.oldLineNumber
            : line.newLineNumber ?? line.oldLineNumber
        lineNumberText = displayedLineNumber.map(String.init) ?? ""
        lineNumberTone = switch line.kind {
        case .addition: .addition
        case .deletion: .deletion
        case .context, .metadata: .normal
        }
        switch line.kind {
        case .addition:
            markerSymbol = "+"
            markerTone = .addition
        case .deletion:
            markerSymbol = "-"
            markerTone = .deletion
        case .metadata:
            markerSymbol = "·"
            markerTone = .metadata
        case .context:
            markerSymbol = ""
            markerTone = .normal
        }
        content.setRenderedLine(
            line,
            language: language,
            backgroundColor: backgroundColor
        )
        needsDisplay = true
    }

    func updateCodeViewport(horizontalOffset: CGFloat, contentWidth: CGFloat) {
        codeContentWidth = contentWidth
        content.setHorizontalOffset(horizontalOffset)
    }

    /// 单行过长时排版会卡顿；只截显示，复制仍是整行。
    /// 截断后行内区间的偏移不再可信，直接不上高亮。
    fileprivate static func contentText(
        for line: GitDiffLine,
        language: GitSyntaxLanguage
    ) -> NSAttributedString {
        DiffHighlightedTextCache.attributedText(for: line, language: language)
    }

    fileprivate static func buildContentText(
        displayString: String,
        syntaxSpans: [GitSyntaxSpan],
        line: GitDiffLine
    ) -> NSAttributedString {
        let font = AgentGitTypography.code
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ]

        guard line.content.utf8.count <= maximumDisplayedColumns else {
            return NSAttributedString(
                string: displayString,
                attributes: attributes
            )
        }

        let text = NSMutableAttributedString(
            string: displayString,
            attributes: attributes
        )
        let limit = text.length
        for span in syntaxSpans {
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
        guard !line.inlineRanges.isEmpty, let highlight = inlineHighlight(for: line.kind) else {
            return NSAttributedString(attributedString: text)
        }

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
        return NSAttributedString(attributedString: text)
    }

    /// 屏幕上这行实际显示的字符。跨行选区按显示字符计位置，复制也照这个取。
    fileprivate static func displayString(for line: GitDiffLine) -> String {
        guard line.content.utf8.count <= maximumDisplayedColumns else {
            return String(line.content.prefix(maximumDisplayedColumns)) + " …"
        }
        return line.content.isEmpty ? " " : line.content
    }

    fileprivate static func syntaxColor(for kind: GitSyntaxTokenKind) -> NSColor {
        switch kind {
        case .keyword: AgentGitPalette.syntaxKeyword
        case .type: AgentGitPalette.syntaxType
        case .string: AgentGitPalette.syntaxString
        case .number: AgentGitPalette.syntaxNumber
        case .comment: AgentGitPalette.syntaxComment
        case .heading: AgentGitPalette.syntaxHeading
        }
    }

    fileprivate static func inlineHighlight(for kind: GitDiffLineKind) -> NSColor? {
        switch kind {
        case .addition: AgentGitPalette.additionInline
        case .deletion: AgentGitPalette.deletionInline
        case .context, .metadata: nil
        }
    }

    fileprivate static let maximumDisplayedColumns = 4_000

    private var backgroundColor: NSColor {
        diffRowBackgroundColor(for: kind)
    }
}

private final class DiffSideBySideCellView: NSTableCellView, DiffCodeViewport, DiffCodeSelectionCell, DiffRowSelectionCell {
    static let identifier = NSUserInterfaceItemIdentifier("diff-side-by-side")
    nonisolated static let sideCodeLeading: CGFloat = 52
    private static let lineNumberMaxX: CGFloat = 36
    private static let markerMinX: CGFloat = 38
    private static let markerWidth: CGFloat = 12

    var codeTextViewsByColumn: [DiffCodeColumn: DiffSelectableTextView] {
        [.old: oldContent, .new: newContent]
    }

    private struct PaneGutterState {
        var kind: GitDiffLineKind?
        var lineNumberText = ""
        var lineNumberTone: DiffGutterTextCache.Tone = .normal
        var markerSymbol = ""
        var markerTone: DiffGutterTextCache.Tone = .normal
        var backgroundColor: NSColor = AgentGitPalette.codeFiller
    }

    private let oldContent = DiffSelectableTextView(
        font: AgentGitTypography.code,
        textColor: AgentGitPalette.codeText
    )
    private let newContent = DiffSelectableTextView(
        font: AgentGitTypography.code,
        textColor: AgentGitPalette.codeText
    )
    private var oldGutter = PaneGutterState()
    private var newGutter = PaneGutterState()
    private var renderedPair: GitDiffLinePair?
    private var renderedLanguage: GitSyntaxLanguage?
    private var hasRenderedPair = false
    private var isRowSelected = false

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsFormat = .RGBA8Uint
        layer?.isOpaque = true
        canDrawSubviewsIntoLayer = true
        oldContent.wantsLayer = false
        newContent.wantsLayer = false
        oldContent.clipsToBounds = false
        newContent.clipsToBounds = false
        oldContent.identifier = NSUserInterfaceItemIdentifier("diff-old-code-content")
        newContent.identifier = NSUserInterfaceItemIdentifier("diff-new-code-content")
        addSubview(oldContent)
        addSubview(newContent)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        let leftPaneWidth = floor(bounds.width * 0.5)
        let rightPaneWidth = max(0, bounds.width - leftPaneWidth)
        oldContent.frame = NSRect(
            x: Self.sideCodeLeading,
            y: 0,
            width: max(0, leftPaneWidth - Self.sideCodeLeading - 8),
            height: bounds.height
        )
        newContent.frame = NSRect(
            x: leftPaneWidth + Self.sideCodeLeading,
            y: 0,
            width: max(0, rightPaneWidth - Self.sideCodeLeading - 8),
            height: bounds.height
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        let appearance = DiffAppearanceVariant(appearance: effectiveAppearance)
        let leftPaneWidth = floor(bounds.width * 0.5)
        let rightPaneWidth = max(0, bounds.width - leftPaneWidth)
        let baselineY = DiffCodeMetrics.baselineY(in: bounds.height)

        drawPane(
            oldGutter,
            originX: 0,
            paneWidth: leftPaneWidth,
            baselineY: baselineY,
            appearance: appearance,
            dirtyRect: dirtyRect,
            in: context
        )
        drawPane(
            newGutter,
            originX: leftPaneWidth,
            paneWidth: rightPaneWidth,
            baselineY: baselineY,
            appearance: appearance,
            dirtyRect: dirtyRect,
            in: context
        )

        let dividerRect = NSRect(x: leftPaneWidth - 0.5, y: 0, width: 1, height: bounds.height)
        if dividerRect.intersects(dirtyRect) {
            context.setFillColor(appearance.resolveCGColor(AgentGitPalette.splitPaneDivider))
            context.fill(dividerRect)
        }
    }

    private func drawPane(
        _ gutter: PaneGutterState,
        originX: CGFloat,
        paneWidth: CGFloat,
        baselineY: CGFloat,
        appearance: DiffAppearanceVariant,
        dirtyRect: NSRect,
        in context: CGContext
    ) {
        let paneRect = NSRect(x: originX, y: 0, width: paneWidth, height: bounds.height)
        let fillRect = paneRect.intersection(dirtyRect)
        guard !fillRect.isNull, fillRect.width > 0, fillRect.height > 0 else {
            return
        }
        context.setFillColor(appearance.resolveCGColor(gutter.backgroundColor))
        context.fill(fillRect)

        if let kind = gutter.kind, let barColor = diffChangeBarColor(for: kind) {
            let barRect = NSRect(x: originX, y: 0, width: AgentGitPalette.diffChangeBarWidth, height: bounds.height)
            if barRect.intersects(dirtyRect) {
                context.setFillColor(appearance.resolveCGColor(barColor))
                context.fill(barRect)
            }
        }
        if isRowSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
            fillRect.fill()
        }

        guard dirtyRect.minX < originX + Self.sideCodeLeading,
              dirtyRect.maxX > originX else {
            return
        }
        if !gutter.lineNumberText.isEmpty {
            let entry = DiffGutterTextCache.entry(
                text: gutter.lineNumberText,
                tone: gutter.lineNumberTone,
                appearance: appearance
            )
            drawFlippedCTLine(
                entry.ctLine,
                at: CGPoint(x: originX + Self.lineNumberMaxX - entry.width, y: baselineY),
                in: context
            )
        }
        if !gutter.markerSymbol.isEmpty {
            let entry = DiffGutterTextCache.entry(
                text: gutter.markerSymbol,
                tone: gutter.markerTone,
                appearance: appearance
            )
            let markerX = originX + Self.markerMinX + (Self.markerWidth - entry.width) * 0.5
            drawFlippedCTLine(
                entry.ctLine,
                at: CGPoint(x: markerX, y: baselineY),
                in: context
            )
        }
    }

    func update(pair: GitDiffLinePair, language: GitSyntaxLanguage) {
        if hasRenderedPair, renderedPair == pair, renderedLanguage == language {
            oldContent.clearSelectionIfNeeded()
            newContent.clearSelectionIfNeeded()
            return
        }
        hasRenderedPair = true
        renderedPair = pair
        renderedLanguage = language
        configurePane(
            gutter: &oldGutter,
            contentView: oldContent,
            line: pair.old,
            isOldSide: true,
            language: language
        )
        configurePane(
            gutter: &newGutter,
            contentView: newContent,
            line: pair.new,
            isOldSide: false,
            language: language
        )
        needsDisplay = true
    }

    private func configurePane(
        gutter: inout PaneGutterState,
        contentView: DiffSelectableTextView,
        line: GitDiffLine?,
        isOldSide: Bool,
        language: GitSyntaxLanguage
    ) {
        guard let line else {
            gutter = PaneGutterState()
            contentView.clearRenderedLine(backgroundColor: AgentGitPalette.codeFiller)
            return
        }
        let background = diffRowBackgroundColor(for: line.kind)
        gutter.kind = line.kind
        gutter.backgroundColor = background
        let number = isOldSide ? line.oldLineNumber : line.newLineNumber
        gutter.lineNumberText = number.map(String.init) ?? ""
        gutter.lineNumberTone = switch line.kind {
        case .addition: .addition
        case .deletion: .deletion
        case .context, .metadata: .normal
        }
        switch (isOldSide, line.kind) {
        case (true, .deletion):
            gutter.markerSymbol = "-"
            gutter.markerTone = .deletion
        case (false, .addition):
            gutter.markerSymbol = "+"
            gutter.markerTone = .addition
        case (_, .metadata):
            gutter.markerSymbol = "·"
            gutter.markerTone = .metadata
        default:
            gutter.markerSymbol = ""
            gutter.markerTone = .normal
        }
        contentView.setRenderedLine(
            line,
            language: language,
            backgroundColor: background
        )
    }

    func updateCodeViewport(horizontalOffset: CGFloat, contentWidth: CGFloat) {
        oldContent.setHorizontalOffset(horizontalOffset)
        newContent.setHorizontalOffset(horizontalOffset)
    }

    func updateRowSelection(_ selected: Bool) {
        guard isRowSelected != selected else { return }
        isRowSelected = selected
        oldContent.setRowSelected(selected)
        newContent.setRowSelected(selected)
        needsDisplay = true
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

struct DiffInlineHighlightSpan: Equatable {
    let minX: CGFloat
    let width: CGFloat
}

struct DiffRenderedLine {
    let displayString: String
    let utf16Length: Int
    let hasVisibleGlyphs: Bool
    let ctLine: CTLine
    let inlineSpans: [DiffInlineHighlightSpan]
    let inlineHighlightColor: CGColor?
}

@MainActor
enum DiffHighlightedTextCache {
    private struct Key: Hashable {
        let content: String
        let kind: GitDiffLineKind
        let inlineRanges: [GitDiffInlineRange]
        let language: GitSyntaxLanguage
    }

    private final class BaseEntry {
        let displayString: String
        let utf16Length: Int
        let hasVisibleGlyphs: Bool
        let syntaxSpans: [GitSyntaxSpan]
        var attributedText: NSAttributedString?
        var variants: [DiffAppearanceVariant: DiffRenderedLine] = [:]

        init(
            displayString: String,
            utf16Length: Int,
            hasVisibleGlyphs: Bool,
            syntaxSpans: [GitSyntaxSpan]
        ) {
            self.displayString = displayString
            self.utf16Length = utf16Length
            self.hasVisibleGlyphs = hasVisibleGlyphs
            self.syntaxSpans = syntaxSpans
        }
    }

    private static let generationLimit = 4_096
    private static var currentGeneration: [Key: BaseEntry] = [:]
    private static var previousGeneration: [Key: BaseEntry] = [:]

    static func attributedText(
        for line: GitDiffLine,
        language: GitSyntaxLanguage
    ) -> NSAttributedString {
        let entry = baseEntry(for: line, language: language)
        if let existing = entry.attributedText {
            return existing
        }
        let built = DiffLineCellView.buildContentText(
            displayString: entry.displayString,
            syntaxSpans: entry.syntaxSpans,
            line: line
        )
        entry.attributedText = built
        return built
    }

    static func renderedVariant(
        for line: GitDiffLine,
        language: GitSyntaxLanguage,
        appearance: DiffAppearanceVariant
    ) -> DiffRenderedLine {
        let entry = baseEntry(for: line, language: language)
        if let existing = entry.variants[appearance] {
            return existing
        }
        let cfText = entry.displayString as CFString
        let length = entry.utf16Length
        let attr = CFAttributedStringCreateMutable(kCFAllocatorDefault, length)!
        CFAttributedStringBeginEditing(attr)
        CFAttributedStringReplaceString(attr, CFRange(location: 0, length: 0), cfText)
        let fullRange = CFRange(location: 0, length: length)
        CFAttributedStringSetAttribute(attr, fullRange, kCTFontAttributeName, DiffCodeMetrics.ctFont)
        CFAttributedStringSetAttribute(
            attr,
            fullRange,
            kCTForegroundColorAttributeName,
            appearance.resolveCGColor(NSColor.labelColor)
        )
        for span in entry.syntaxSpans {
            let clampedLocation = min(span.location, length)
            let clampedLength = min(span.length, max(0, length - span.location))
            guard clampedLength > 0 else {
                continue
            }
            let cfRange = CFRange(location: clampedLocation, length: clampedLength)
            CFAttributedStringSetAttribute(
                attr,
                cfRange,
                kCTForegroundColorAttributeName,
                appearance.resolveCGColor(DiffLineCellView.syntaxColor(for: span.kind))
            )
            if span.kind == .heading {
                CFAttributedStringSetAttribute(
                    attr,
                    cfRange,
                    kCTFontAttributeName,
                    DiffCodeMetrics.ctEmphasizedFont
                )
            }
        }
        CFAttributedStringEndEditing(attr)
        let ctLine = CTLineCreateWithAttributedString(attr)

        var inlineSpans: [DiffInlineHighlightSpan] = []
        var inlineHighlightColor: CGColor?
        if line.content.utf8.count <= DiffLineCellView.maximumDisplayedColumns,
           !line.inlineRanges.isEmpty,
           let highlightNSColor = DiffLineCellView.inlineHighlight(for: line.kind) {
            inlineHighlightColor = appearance.resolveCGColor(highlightNSColor)
            inlineSpans.reserveCapacity(line.inlineRanges.count)
            for range in line.inlineRanges {
                let clampedLocation = min(max(0, range.location), length)
                let clampedLength = min(max(0, range.length), max(0, length - clampedLocation))
                guard clampedLength > 0 else {
                    continue
                }
                let startX = CTLineGetOffsetForStringIndex(ctLine, clampedLocation, nil)
                let endX = CTLineGetOffsetForStringIndex(ctLine, clampedLocation + clampedLength, nil)
                let minX = min(startX, endX)
                let width = abs(endX - startX)
                if width > 0 {
                    inlineSpans.append(DiffInlineHighlightSpan(minX: minX, width: width))
                }
            }
        }

        let built = DiffRenderedLine(
            displayString: entry.displayString,
            utf16Length: length,
            hasVisibleGlyphs: entry.hasVisibleGlyphs,
            ctLine: ctLine,
            inlineSpans: inlineSpans,
            inlineHighlightColor: inlineHighlightColor
        )
        entry.variants[appearance] = built
        return built
    }

    private static func baseEntry(
        for line: GitDiffLine,
        language: GitSyntaxLanguage
    ) -> BaseEntry {
        let key = Key(
            content: line.content,
            kind: line.kind,
            inlineRanges: line.inlineRanges,
            language: language
        )
        if let cached = currentGeneration[key] {
            return cached
        }
        if let cached = previousGeneration[key] {
            promote(cached, for: key)
            return cached
        }
        let display = DiffLineCellView.displayString(for: line)
        let utf16Length = (display as NSString).length
        let spans: [GitSyntaxSpan]
        if line.kind == .metadata || line.content.utf8.count > DiffLineCellView.maximumDisplayedColumns || line.content.isEmpty {
            spans = []
        } else {
            spans = DiffSyntaxHighlighter.spans(in: line.content, language: language)
        }
        let built = BaseEntry(
            displayString: display,
            utf16Length: utf16Length,
            hasVisibleGlyphs: !line.content.isEmpty,
            syntaxSpans: spans
        )
        promote(built, for: key)
        return built
    }

    private static func promote(_ value: BaseEntry, for key: Key) {
        if currentGeneration.count >= generationLimit {
            previousGeneration = currentGeneration
            currentGeneration = [:]
            currentGeneration.reserveCapacity(min(generationLimit, 512))
        }
        currentGeneration[key] = value
    }
}

final class DiffSelectableTextView: NSView {
    /// AppKit 把点击直接派给命中的这个文本视图，表格的 mouseDown 不会收到，
    /// 所以跨行选择从这里交回给表格统一处理。
    var mouseDownHandler: ((DiffSelectableTextView, NSEvent) -> Bool)?
    var contextMenuHandler: ((DiffSelectableTextView, NSEvent) -> NSMenu?)?

    private let defaultFont: NSFont
    private let defaultTextColor: NSColor
    private var renderedLine: GitDiffLine?
    private var renderedLanguage: GitSyntaxLanguage?
    private var renderedVariant: DiffRenderedLine?
    private var renderedAppearance: DiffAppearanceVariant?
    private var rowBackgroundColor: NSColor = AgentGitPalette.codeBackground
    private var isRowSelected = false
    private var horizontalOffset: CGFloat = 0
    private var fallbackAttributedText: NSAttributedString?
    private var fallbackCTLine: CTLine?
    private var highlightRange = NSRange(location: 0, length: 0)

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    init(font: NSFont, textColor: NSColor) {
        self.defaultFont = font
        self.defaultTextColor = textColor
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        nil
    }

    var string: String {
        get {
            if let renderedVariant {
                return renderedVariant.displayString
            }
            return fallbackAttributedText?.string ?? ""
        }
        set {
            if newValue.isEmpty {
                setAttributedString(NSAttributedString())
            } else {
                setAttributedString(
                    NSAttributedString(
                        string: newValue,
                        attributes: [
                            .font: defaultFont,
                            .foregroundColor: defaultTextColor
                        ]
                    )
                )
            }
        }
    }

    var textLength: Int {
        if let renderedVariant {
            return renderedVariant.utf16Length
        }
        return fallbackAttributedText?.length ?? 0
    }

    func selectedRange() -> NSRange {
        highlightRange
    }

    func clearSelectionIfNeeded() {
        if highlightRange.length > 0 {
            highlightRange = NSRange(location: 0, length: 0)
            needsDisplay = true
        }
    }

    func setRowSelected(_ selected: Bool) {
        guard isRowSelected != selected else {
            return
        }
        isRowSelected = selected
        needsDisplay = true
    }

    func setHorizontalOffset(_ offset: CGFloat) {
        guard horizontalOffset != offset else {
            return
        }
        horizontalOffset = offset
        needsDisplay = true
    }

    func clearRenderedLine(backgroundColor: NSColor) {
        let hadContent = renderedVariant != nil || (fallbackAttributedText?.length ?? 0) > 0 || highlightRange.length > 0
        let backgroundChanged = rowBackgroundColor !== backgroundColor
        renderedLine = nil
        renderedLanguage = nil
        renderedVariant = nil
        fallbackAttributedText = nil
        fallbackCTLine = nil
        rowBackgroundColor = backgroundColor
        highlightRange = NSRange(location: 0, length: 0)
        if hadContent || backgroundChanged {
            needsDisplay = true
        }
    }

    func setRenderedLine(
        _ line: GitDiffLine,
        language: GitSyntaxLanguage,
        backgroundColor: NSColor
    ) {
        let appearance = DiffAppearanceVariant(appearance: effectiveAppearance)
        if renderedLine == line,
           renderedLanguage == language,
           renderedAppearance == appearance,
           renderedVariant != nil {
            let backgroundChanged = rowBackgroundColor !== backgroundColor
            rowBackgroundColor = backgroundColor
            if highlightRange.length > 0 {
                highlightRange = NSRange(location: 0, length: 0)
                needsDisplay = true
            } else if backgroundChanged {
                needsDisplay = true
            }
            return
        }
        renderedLine = line
        renderedLanguage = language
        renderedAppearance = appearance
        rowBackgroundColor = backgroundColor
        fallbackAttributedText = nil
        fallbackCTLine = nil
        renderedVariant = DiffHighlightedTextCache.renderedVariant(
            for: line,
            language: language,
            appearance: appearance
        )
        highlightRange = NSRange(location: 0, length: 0)
        needsDisplay = true
    }

    func setAttributedString(_ value: NSAttributedString) {
        if renderedVariant == nil,
           let existing = fallbackAttributedText,
           existing === value || existing.isEqual(to: value) {
            clearSelectionIfNeeded()
            return
        }
        renderedLine = nil
        renderedLanguage = nil
        renderedVariant = nil
        fallbackAttributedText = value
        fallbackCTLine = nil
        highlightRange = NSRange(location: 0, length: 0)
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let nextAppearance = DiffAppearanceVariant(appearance: effectiveAppearance)
        guard nextAppearance != renderedAppearance else {
            return
        }
        renderedAppearance = nextAppearance
        if let line = renderedLine, let language = renderedLanguage {
            renderedVariant = DiffHighlightedTextCache.renderedVariant(
                for: line,
                language: language,
                appearance: nextAppearance
            )
            needsDisplay = true
        } else if fallbackAttributedText != nil {
            fallbackCTLine = nil
            needsDisplay = true
        }
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
        characterIndex(at: convert(point, from: nil))
    }

    func characterIndex(at localPoint: NSPoint) -> Int {
        let limit = textLength
        let lineX = localPoint.x + horizontalOffset
        guard limit > 0, lineX > 0, let ctLine = resolvedCTLine() else {
            return 0
        }
        let index = CTLineGetStringIndexForPosition(
            ctLine,
            CGPoint(x: lineX, y: 0)
        )
        guard index != kCFNotFound else {
            return 0
        }
        return min(max(0, index), limit)
    }

    func wordRange(at index: Int) -> NSRange {
        let limit = textLength
        guard limit > 0 else {
            return NSRange(location: 0, length: 0)
        }
        let clampedIndex = min(max(0, index), limit - 1)
        if let line = renderedLine, let language = renderedLanguage {
            return DiffHighlightedTextCache.attributedText(for: line, language: language)
                .doubleClick(at: clampedIndex)
        }
        return fallbackAttributedText?.doubleClick(at: clampedIndex)
            ?? NSRange(location: 0, length: 0)
    }

    override func mouseDown(with event: NSEvent) {
        (enclosingScrollView as? DiffStackScrollView)?.cancelFlingSubstepping()
        guard mouseDownHandler?(self, event) != true else {
            return
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuHandler?(self, event) ?? super.menu(for: event)
    }

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .staticText
    }

    override func accessibilityValue() -> Any? {
        string
    }

    override func draw(_ dirtyRect: NSRect) {
        let parentDrawsRowBackground = superview?.canDrawSubviewsIntoLayer == true
        if parentDrawsRowBackground, highlightRange.length == 0 {
            if let variant = renderedVariant {
                if !variant.hasVisibleGlyphs && variant.inlineSpans.isEmpty {
                    return
                }
            } else if (fallbackAttributedText?.length ?? 0) == 0 {
                return
            }
        }
        let clipRect = bounds.intersection(dirtyRect)
        guard !clipRect.isNull, clipRect.width > 0, clipRect.height > 0,
              let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        let appearance = renderedAppearance ?? DiffAppearanceVariant(appearance: effectiveAppearance)
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: clipRect)

        if !parentDrawsRowBackground {
            context.setFillColor(appearance.resolveCGColor(rowBackgroundColor))
            context.fill(clipRect)

            if isRowSelected {
                NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
                clipRect.fill()
            }
        }

        if let variant = renderedVariant {
            let baselineY = DiffCodeMetrics.baselineY(in: bounds.height)
            if !variant.inlineSpans.isEmpty, let inlineColor = variant.inlineHighlightColor {
                let inlineTop = max(0, floor(baselineY - DiffCodeMetrics.ascent - 1))
                let inlineBottom = min(bounds.height, ceil(baselineY + DiffCodeMetrics.descent + 1))
                let inlineHeight = max(0, inlineBottom - inlineTop)
                context.setFillColor(inlineColor)
                for span in variant.inlineSpans {
                    let x = span.minX - horizontalOffset
                    guard x + span.width > clipRect.minX, x < clipRect.maxX else {
                        continue
                    }
                    context.fill(CGRect(x: x, y: inlineTop, width: span.width, height: inlineHeight))
                }
            }
            drawSelectionHighlight(ctLine: variant.ctLine, clipRect: clipRect)
            if variant.hasVisibleGlyphs {
                drawFlippedCTLine(
                    variant.ctLine,
                    at: CGPoint(x: -horizontalOffset, y: baselineY),
                    in: context
                )
            }
            return
        }

        if let fallback = fallbackAttributedText, fallback.length > 0 {
            if let ctLine = resolvedCTLine() {
                drawSelectionHighlight(ctLine: ctLine, clipRect: clipRect)
            }
            fallback.draw(at: NSPoint(x: -horizontalOffset, y: 1))
        }
    }

    /// 选中底色铺满整行高，跨行选区在行与行之间才不会断成一节一节。
    private func drawSelectionHighlight(ctLine: CTLine, clipRect: NSRect) {
        guard highlightRange.length > 0 else {
            return
        }
        let startX = CTLineGetOffsetForStringIndex(ctLine, highlightRange.location, nil) - horizontalOffset
        let endX = CTLineGetOffsetForStringIndex(ctLine, NSMaxRange(highlightRange), nil) - horizontalOffset
        let minX = min(startX, endX)
        let width = abs(endX - startX)
        guard width > 0, minX + width > clipRect.minX, minX < clipRect.maxX else {
            return
        }
        AgentGitPalette.codeSelection.setFill()
        NSRect(
            x: minX,
            y: 0,
            width: width,
            height: bounds.height
        ).fill()
    }

    private func resolvedCTLine() -> CTLine? {
        if let renderedVariant {
            return renderedVariant.ctLine
        }
        if let fallbackCTLine {
            return fallbackCTLine
        }
        guard let fallbackAttributedText, fallbackAttributedText.length > 0 else {
            return nil
        }
        let created = CTLineCreateWithAttributedString(fallbackAttributedText)
        fallbackCTLine = created
        return created
    }
}

@MainActor
private func diffRowBackgroundColor(for kind: GitDiffLineKind) -> NSColor {
    switch kind {
    case .addition: AgentGitPalette.additionBackground
    case .deletion: AgentGitPalette.deletionBackground
    case .metadata: AgentGitPalette.metadataBackground
    case .context: AgentGitPalette.codeBackground
    }
}

/// 增删行最左侧竖条的颜色；上下文和元数据行不画。
@MainActor
private func diffChangeBarColor(for kind: GitDiffLineKind) -> NSColor? {
    switch kind {
    case .addition: AgentGitPalette.additionText
    case .deletion: AgentGitPalette.deletionText
    case .context, .metadata: nil
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
}
