import AgentGitCore
@testable import AgentGitApp
import AppKit
import Foundation
import SwiftUI
import Testing

@Test func watchIndexLimitsWorkingTreeRootsToActiveWorktreeWhileKeepingGitMetadata() {
    let mainRoot = URL(fileURLWithPath: "/repos/monorepo/main")
    let featureRoot = URL(fileURLWithPath: "/repos/monorepo/feature")
    let fallbackRoot = URL(fileURLWithPath: "/repos/monorepo/recovering")
    let commonGit = URL(fileURLWithPath: "/repos/monorepo/main/.git")
    let featureGit = URL(fileURLWithPath: "/repos/monorepo/main/.git/worktrees/feature")

    let mainWorktree = GitWorktree(
        rootURL: mainRoot,
        headOID: "1111111111111111111111111111111111111111",
        branchRef: "refs/heads/main",
        isBare: false,
        isDetached: false,
        lockedReason: nil,
        prunableReason: nil
    )
    let featureWorktree = GitWorktree(
        rootURL: featureRoot,
        headOID: "2222222222222222222222222222222222222222",
        branchRef: "refs/heads/feature",
        isBare: false,
        isDetached: false,
        lockedReason: nil,
        prunableReason: nil
    )
    let fallbackWorktree = GitWorktree(
        rootURL: fallbackRoot,
        headOID: nil,
        branchRef: nil,
        isBare: false,
        isDetached: true,
        lockedReason: nil,
        prunableReason: nil
    )

    let project = GitProject(rootURL: mainRoot)
    let projectState = ProjectState(
        project: project,
        snapshot: GitProjectSnapshot(
            project: project,
            worktrees: [
                GitWorktreeSnapshot(
                    worktree: mainWorktree,
                    status: .clean,
                    diffStat: .zero,
                    lastActivityAt: Date(timeIntervalSince1970: 100),
                    errorMessage: nil,
                    eventWatchURLs: [mainRoot, commonGit]
                ),
                GitWorktreeSnapshot(
                    worktree: featureWorktree,
                    status: .clean,
                    diffStat: .zero,
                    lastActivityAt: Date(timeIntervalSince1970: 200),
                    errorMessage: nil,
                    eventWatchURLs: [featureRoot, featureGit, commonGit]
                ),
                GitWorktreeSnapshot(
                    worktree: fallbackWorktree,
                    status: .clean,
                    diffStat: .zero,
                    lastActivityAt: .distantPast,
                    errorMessage: "Unreadable gitdir",
                    hasUsableState: false,
                    eventWatchURLs: [fallbackRoot]
                )
            ],
            refreshedAt: Date(timeIntervalSince1970: 200)
        )
    )

    let index = RepositoryWatchIndex(
        projects: [projectState],
        activeWorkingTreeIDs: [featureWorktree.id]
    )
    let watched = Set(index.watchedPaths)

    #expect(watched.contains(featureRoot.path))
    #expect(watched.contains(featureGit.path))
    #expect(watched.contains(commonGit.path))
    #expect(watched.contains(fallbackRoot.path))
    #expect(!watched.contains(mainRoot.path))
    #expect(index.allWorktreeIDs == [mainWorktree.id, featureWorktree.id, fallbackWorktree.id])

    let backgroundBuildImpact = index.impact(for: ["/repos/monorepo/main/DerivedData/Build.o"])
    #expect(backgroundBuildImpact.isEmpty)

    let activeEditImpact = index.impact(for: ["/repos/monorepo/feature/Sources/App.swift"])
    #expect(activeEditImpact.contentPathsByWorktreeID[featureWorktree.id] == ["/repos/monorepo/feature/Sources/App.swift"])

    let primaryIndexImpact = index.impact(for: ["/repos/monorepo/main/.git/index"])
    #expect(primaryIndexImpact.metadataWorktreeIDs == [mainWorktree.id])

    let mainBranchRefImpact = index.impact(for: ["/repos/monorepo/main/.git/refs/heads/main"])
    #expect(mainBranchRefImpact.metadataWorktreeIDs == [mainWorktree.id])
}

@Test @MainActor func diffHighlightedTextCacheAndSelectableTextViewBehaveConsistently() {
    _ = NSApplication.shared

    let firstLine = GitDiffLine(
        id: 1,
        kind: .addition,
        oldLineNumber: nil,
        newLineNumber: 10,
        content: "let greeting = \"hello world\""
    )
    let duplicateContentAtDifferentLine = GitDiffLine(
        id: 42,
        kind: .addition,
        oldLineNumber: nil,
        newLineNumber: 99,
        content: "let greeting = \"hello world\""
    )
    let inlineHighlightedLine = GitDiffLine(
        id: 2,
        kind: .addition,
        oldLineNumber: nil,
        newLineNumber: 11,
        content: "let greeting = \"hello world\"",
        inlineRanges: [GitDiffInlineRange(location: 4, length: 8)]
    )

    let cachedA = DiffHighlightedTextCache.attributedText(for: firstLine, language: .swift)
    let cachedB = DiffHighlightedTextCache.attributedText(for: duplicateContentAtDifferentLine, language: .swift)
    let cachedInline = DiffHighlightedTextCache.attributedText(for: inlineHighlightedLine, language: .swift)

    #expect(cachedA === cachedB)
    #expect(cachedA !== cachedInline)

    let textView = DiffSelectableTextView(
        font: AgentGitTypography.code,
        textColor: AgentGitPalette.codeText
    )
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 20)
    textView.setAttributedString(cachedA)

    #expect(textView.textLength == firstLine.content.utf16.count)
    #expect(textView.characterIndex(at: NSPoint(x: -5, y: 10)) == 0)
    let midIndex = textView.characterIndex(at: NSPoint(x: 45, y: 10))
    #expect(midIndex > 0 && midIndex < textView.textLength)
    #expect(textView.characterIndex(at: NSPoint(x: 390, y: 10)) == textView.textLength)

    let greetingRange = textView.wordRange(at: 5)
    #expect((firstLine.content as NSString).substring(with: greetingRange) == "greeting")

    textView.setHighlightRange(NSRange(location: 4, length: 500))
    #expect(textView.selectedRange() == NSRange(location: 4, length: textView.textLength - 4))
    #expect(!shouldToggleDiffRow(for: textView))
}

@Test @MainActor func renderedLineHorizontalOffsetAndOffscreenDrawingProduceVisibleGlyphs() throws {
    _ = NSApplication.shared

    let line = GitDiffLine(
        id: 7,
        kind: .addition,
        oldLineNumber: nil,
        newLineNumber: 24,
        content: "public func calculateSmoothScrollVelocity(deltaY: Double) -> Double { return deltaY * 120.0 }",
        inlineRanges: [GitDiffInlineRange(location: 12, length: 29)]
    )

    let textView = DiffSelectableTextView(
        font: AgentGitTypography.code,
        textColor: AgentGitPalette.codeText
    )
    textView.frame = NSRect(x: 0, y: 0, width: 320, height: 20)
    textView.setRenderedLine(
        line,
        language: .swift,
        backgroundColor: AgentGitPalette.additionBackground
    )

    #expect(textView.isOpaque)
    #expect(!textView.clipsToBounds)
    #expect(textView.textLength == line.content.utf16.count)

    let indexAt120 = textView.characterIndex(at: NSPoint(x: 120, y: 10))
    textView.setHorizontalOffset(80)
    let indexAt40Scrolled80 = textView.characterIndex(at: NSPoint(x: 40, y: 10))
    #expect(indexAt120 == indexAt40Scrolled80)

    let word = textView.wordRange(at: 15)
    #expect((line.content as NSString).substring(with: word) == "calculateSmoothScrollVelocity")

    textView.setHorizontalOffset(0)
    for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
        textView.appearance = NSAppearance(named: appearanceName)
        let rep = try #require(textView.bitmapImageRepForCachingDisplay(in: textView.bounds))
        textView.cacheDisplay(in: textView.bounds, to: rep)

        let cornerColor = try #require(rep.colorAt(x: rep.pixelsWide - 2, y: 1))
        var differingPixels = 0
        for x in 0..<min(rep.pixelsWide, 240) {
            for y in 2..<(rep.pixelsHigh - 2) {
                guard let pixel = rep.colorAt(x: x, y: y) else { continue }
                let delta = abs(pixel.redComponent - cornerColor.redComponent)
                    + abs(pixel.greenComponent - cornerColor.greenComponent)
                    + abs(pixel.blueComponent - cornerColor.blueComponent)
                if delta > 0.08 {
                    differingPixels += 1
                }
            }
        }
        #expect(differingPixels > 25)
    }
}

@Test @MainActor func longDiffLinesKeepViewportSizedSingleLayerCellsInUnifiedAndSplitModes() throws {
    _ = NSApplication.shared
    let scrollView = DiffStackScrollView(frame: NSRect(x: 0, y: 0, width: 820, height: 260))
    let longSegment = String(repeating: "let segmentValue = 42; ", count: 120)
    var file = makeTestDiffFile(path: "WideFile.swift", lineCount: 12)
    var updatedLines = try #require(file.diff?.hunks.first?.lines)
    updatedLines[0] = GitDiffLine(
        id: 1,
        kind: .addition,
        oldLineNumber: nil,
        newLineNumber: 1,
        content: longSegment
    )
    let updatedDiff = GitFileDiff(
        change: try #require(file.diff?.change),
        scope: .working,
        hunks: [
            GitDiffHunk(
                id: 0,
                header: "@@ -0,0 +1,12 @@",
                oldStart: 0,
                oldCount: 0,
                newStart: 1,
                newCount: 12,
                lines: updatedLines
            )
        ],
        state: .textual
    )
    file = DiffStackFile(
        id: file.id,
        path: file.path,
        originalPath: nil,
        status: .modified,
        statusLabel: "M",
        isExpanded: true,
        isFocused: false,
        isReviewed: false,
        showsWholeFile: false,
        isLoadingWholeFile: false,
        canToggleWholeFile: false,
        canOpenWorkingFile: false,
        canOpenInVisualStudioCode: false,
        canApplyPrimaryAction: false,
        canDiscard: false,
        isMutationEnabled: false,
        mutationSnapshotID: nil,
        contextGaps: [],
        mutationMode: nil,
        diff: updatedDiff,
        imageDiff: nil
    )
    let group = DiffStackGroup(
        id: "working",
        title: "Working",
        emptyMessage: "",
        isExpanded: true,
        files: [file]
    )

    for layoutMode in [DiffLayoutMode.unified, .sideBySide] {
        scrollView.display(groups: [group], layout: layoutMode, scrollTarget: nil)
        scrollView.layoutSubtreeIfNeeded()

        let table = try #require(scrollView.documentView as? NSTableView)
        let visibleRange = table.rows(in: table.visibleRect)
        #expect(visibleRange.length > 0)

        var inspectedCodeViews = 0
        for row in visibleRange.location..<NSMaxRange(visibleRange) {
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) else {
                continue
            }
            cell.layoutSubtreeIfNeeded()
            for subview in cell.subviews {
                if let codeView = subview as? DiffSelectableTextView {
                    inspectedCodeViews += 1
                    #expect(codeView.frame.width <= scrollView.bounds.width)
                    #expect(codeView.isOpaque)
                    #expect(cell.canDrawSubviewsIntoLayer)
                    #expect(cell.isOpaque)
                }
            }
        }
        #expect(inspectedCodeViews > 0)
    }
}

@Test @MainActor func inMemoryScrollOffsetSkipsLiveScrollPersistenceUntilScrollEndsOrFlushes() throws {
    let suiteName = "AgentGitTests.ScrollState.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = ReviewStateStore(defaults: defaults)
    let key = ReviewStateKey(worktreeID: "/repos/demo", context: .pending)

    store.recordScrollOffsetInMemory(120, for: key)
    store.recordScrollOffsetInMemory(360, for: key)
    #expect(store.scrollOffset(for: key) == 360)
    #expect(defaults.data(forKey: "agentgit.review-state.v1") == nil)

    // 滚动结束时即使最终位置与内存中一致，也必须落盘而不能因差值小于 0.5 被跳过。
    store.saveScrollOffset(360, for: key)
    store.flush()
    #expect(defaults.data(forKey: "agentgit.review-state.v1") != nil)

    let reloaded = ReviewStateStore(defaults: defaults)
    #expect(reloaded.scrollOffset(for: key) == 360)
}

@Test @MainActor func focusingFileScrollsWithinMultiFileDiffStreamWithoutHidingSiblings() throws {
    _ = NSApplication.shared
    let scrollView = DiffStackScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 220))
    let first = makeTestDiffFile(path: "First.swift", lineCount: 35)
    let second = makeTestDiffFile(path: "Second.swift", lineCount: 35)

    scrollView.display(
        groups: [
            DiffStackGroup(
                id: "working",
                title: "Working",
                emptyMessage: "",
                isExpanded: true,
                files: [first, second]
            )
        ],
        layout: .unified,
        scrollTarget: nil
    )
    scrollView.layoutSubtreeIfNeeded()

    let table = try #require(scrollView.documentView as? NSTableView)
    let totalRowsBeforeFocus = table.numberOfRows
    #expect(totalRowsBeforeFocus > 70)
    #expect(scrollView.contentView.bounds.minY == 0)

    scrollView.perform(DiffStackCommand(id: 1, action: .focusFile("Second.swift")))
    scrollView.layoutSubtreeIfNeeded()

    #expect(table.numberOfRows == totalRowsBeforeFocus)
    #expect(scrollView.contentView.bounds.minY > 400)
}

@Test @MainActor func movingToNextFileHunkLeavesOnlyActualStickyHeightAbove() throws {
    _ = NSApplication.shared
    let fileHeight = ReviewWorkspaceStyle.fileHeaderHeight
    // commit 视图的分组没有标题，只给文件标题留位置；带标题的分组还要加上分组标题。
    for (title, reservedHeight) in [(String?.none, fileHeight), ("Working", 32 + fileHeight)] {
        let scrollView = DiffStackScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 220))
        scrollView.display(
            groups: [
                DiffStackGroup(
                    id: "files",
                    title: title,
                    emptyMessage: "",
                    isExpanded: true,
                    files: [
                        makeTestDiffFile(path: "First.swift", lineCount: 35),
                        makeTestDiffFile(path: "Second.swift", lineCount: 35)
                    ]
                )
            ],
            layout: .unified,
            scrollTarget: nil
        )
        scrollView.layoutSubtreeIfNeeded()
        let table = try #require(scrollView.documentView as? NSTableView)

        // 第一次显示时当前 hunk 可能已经是第一个，按需多跳一次，直到落到第二个文件。
        for _ in 0..<3 where table.selectedRow < 0 || table.rect(ofRow: table.selectedRow).minY < 300 {
            #expect(scrollView.moveHunk(by: 1))
            scrollView.layoutSubtreeIfNeeded()
        }
        #expect(table.rect(ofRow: table.selectedRow).minY > 300)

        // 第二个文件的第一个 hunk 紧跟在它的文件标题后面，文件标题正好落在吸顶位置，
        // 不能留出上一个文件的吸顶标题。
        let hunkMinY = table.rect(ofRow: table.selectedRow).minY
        #expect(scrollView.contentView.bounds.minY == hunkMinY - reservedHeight)
        #expect(table.rect(ofRow: table.selectedRow - 1).minY == hunkMinY - fileHeight)
    }
}

@Test @MainActor func multiFileHeadersFlattenLayersEliminateRowTrackingAreasAndSupport165Hz() throws {
    _ = NSApplication.shared

    #expect(!DiffStackScrollView.isCompatibleWithResponsiveScrolling)

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    let scrollView = DiffStackScrollView(frame: NSRect(x: 0, y: 0, width: 1000, height: 640))
    window.contentView = scrollView
    scrollView.ensureFlingDisplayLink(screenMaxFPS: 165)
    #expect(scrollView.appliedFlingDisplayLinkMaxFPS == 165)

    let firstBase = makeTestDiffFile(path: "MMFlutter/app/ting_ui_page.swift", lineCount: 4)
    let secondChange = GitFileChange(
        path: "MMFlutter/base/list_content_width.swift",
        originalPath: nil,
        indexStatus: ".",
        worktreeStatus: "M",
        kind: .ordinary
    )
    let secondDiff = GitFileDiff(
        change: secondChange,
        scope: .working,
        hunks: [
            GitDiffHunk(
                id: 0,
                header: "@@ -1,2 +1,2 @@",
                oldStart: 1,
                oldCount: 2,
                newStart: 1,
                newCount: 2,
                lines: [
                    GitDiffLine(id: 1, kind: .deletion, oldLineNumber: 1, newLineNumber: nil, content: "let oldA = 1"),
                    GitDiffLine(id: 2, kind: .deletion, oldLineNumber: 2, newLineNumber: nil, content: "let oldB = 2"),
                    GitDiffLine(id: 3, kind: .addition, oldLineNumber: nil, newLineNumber: 1, content: "let newA = 10"),
                    GitDiffLine(id: 4, kind: .addition, oldLineNumber: nil, newLineNumber: 2, content: "let newB = 20")
                ]
            )
        ],
        state: .textual
    )
    let secondBase = DiffStackFile(
        id: secondChange.path,
        path: secondChange.path,
        originalPath: nil,
        status: .modified,
        statusLabel: "M",
        isExpanded: true,
        isFocused: false,
        isReviewed: false,
        showsWholeFile: false,
        isLoadingWholeFile: false,
        canToggleWholeFile: true,
        canOpenWorkingFile: true,
        canOpenInVisualStudioCode: true,
        canApplyPrimaryAction: true,
        canDiscard: true,
        isMutationEnabled: true,
        mutationSnapshotID: nil,
        contextGaps: [],
        mutationMode: .working,
        diff: secondDiff,
        imageDiff: nil
    )
    let files = [firstBase, secondBase].map { base in
        DiffStackFile(
            id: base.id,
            path: base.path,
            originalPath: nil,
            status: .modified,
            statusLabel: "M",
            isExpanded: true,
            isFocused: false,
            isReviewed: false,
            showsWholeFile: false,
            isLoadingWholeFile: false,
            canToggleWholeFile: true,
            canOpenWorkingFile: true,
            canOpenInVisualStudioCode: true,
            canApplyPrimaryAction: true,
            canDiscard: true,
            isMutationEnabled: true,
            mutationSnapshotID: nil,
            contextGaps: [],
            mutationMode: .working,
            diff: base.diff,
            imageDiff: nil
        )
    }

    let folder = DiffStackFolder(
        id: "MMFlutter",
        title: "MMFlutter",
        isExpanded: true,
        fileIDs: files.map(\.id)
    )
    let group = DiffStackGroup(
        id: "working",
        title: "Working",
        emptyMessage: "",
        isExpanded: true,
        files: files,
        folders: [folder]
    )

    scrollView.display(groups: [group], layout: .sideBySide, scrollTarget: nil)
    scrollView.layoutSubtreeIfNeeded()
    scrollView.displayIfNeeded()

    let table = try #require(scrollView.documentView as? NSTableView)
    #expect(table.trackingAreas.count == 1)

    let visibleRange = table.rows(in: table.visibleRect)
    #expect(visibleRange.length > 0)

    var groupCellCount = 0
    var folderCellCount = 0
    var fileCellCount = 0
    var hunkCellCount = 0
    var unifiedLineCellCount = 0
    var sideBySideCellCount = 0

    for row in visibleRange.location..<NSMaxRange(visibleRange) {
        let rowView = try #require(table.rowView(atRow: row, makeIfNecessary: true))
        #expect(rowView.wantsUpdateLayer)

        let cell = try #require(table.view(atColumn: 0, row: row, makeIfNecessary: true))
        cell.layoutSubtreeIfNeeded()
        cell.displayIfNeeded()
        #expect(cell.trackingAreas.isEmpty)

        let typeName = String(describing: type(of: cell))
        switch typeName {
        case "DiffGroupCellView":
            groupCellCount += 1
        case "DiffFolderCellView":
            folderCellCount += 1
        case "DiffFileCellView":
            fileCellCount += 1
        case "DiffHunkCellView":
            hunkCellCount += 1
        case "DiffLineCellView":
            unifiedLineCellCount += 1
        case "DiffSideBySideCellView":
            sideBySideCellCount += 1
        default:
            break
        }

        if [
            "DiffGroupCellView",
            "DiffFolderCellView",
            "DiffFileCellView",
            "DiffHunkCellView",
            "DiffLineCellView",
            "DiffSideBySideCellView"
        ].contains(typeName) {
            #expect(cell.canDrawSubviewsIntoLayer)
            #expect(cell.isOpaque)
            #expect(cell.layer != nil)
            for subview in cell.subviews {
                #expect(subview.trackingAreas.isEmpty)
                if !(subview is DiffDisclosureView) {
                    #expect(!subview.wantsLayer)
                    #expect(subview.layer == nil)
                }
            }
        }
    }

    #expect(groupCellCount == 1)
    #expect(folderCellCount == 1)
    #expect(fileCellCount == 2)
    #expect(hunkCellCount == 2)
    #expect(unifiedLineCellCount == 4)
    #expect(sideBySideCellCount == 2)
}

@Test func loadHistoryPageSkipsTreeDiffStatAndReusesReferencesAcrossPages() async throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appending(path: "AgentGitTests.History.\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try runGit(["init", "-b", "main"], in: tempDir)
    try runGit(["config", "user.name", "Test User"], in: tempDir)
    try runGit(["config", "user.email", "test@example.com"], in: tempDir)

    for index in 1...3 {
        let fileURL = tempDir.appending(path: "file\(index).txt")
        try "content \(index)\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try runGit(["add", "file\(index).txt"], in: tempDir)
        try runGit(["commit", "-m", "Commit number \(index)"], in: tempDir)
    }
    try runGit(["tag", "v1.0.0"], in: tempDir)

    let service = GitRepositoryService()
    let snapshot = try await service.loadProject(at: tempDir)
    let worktree = try #require(snapshot.worktrees.first?.worktree)

    let firstPage = try await service.loadHistoryPage(
        worktree: worktree,
        revision: nil,
        offset: 0,
        pageSize: 2
    )
    #expect(firstPage.commits.count == 2)
    #expect(firstPage.hasMore)
    #expect(firstPage.commits[0].subject == "Commit number 3")
    #expect(firstPage.commits[0].changedFileCount == nil)
    #expect(firstPage.commits[0].references.contains { $0.label == "v1.0.0" })

    let secondPage = try await service.loadHistoryPage(
        worktree: worktree,
        revision: nil,
        offset: 2,
        pageSize: 2
    )
    #expect(secondPage.commits.count == 1)
    #expect(!secondPage.hasMore)
    #expect(secondPage.commits[0].subject == "Commit number 1")

    let searchQuery = try #require(GitHistorySearchQuery("number 2"))
    let searchPage = try await service.searchHistoryPage(
        worktree: worktree,
        revision: nil,
        query: searchQuery,
        offset: 0,
        pageSize: 10
    )
    #expect(searchPage.commits.map(\.subject) == ["Commit number 2"])
    #expect(searchPage.commits[0].changedFileCount == nil)
}

@MainActor
private func makeTestDiffFile(path: String, lineCount: Int) -> DiffStackFile {
    let change = GitFileChange(
        path: path,
        originalPath: nil,
        indexStatus: ".",
        worktreeStatus: "M",
        kind: .ordinary
    )
    let lines = (1...lineCount).map { number in
        GitDiffLine(
            id: number,
            kind: .addition,
            oldLineNumber: nil,
            newLineNumber: number,
            content: "let value\(number) = \(number)"
        )
    }
    let diff = GitFileDiff(
        change: change,
        scope: .working,
        hunks: [
            GitDiffHunk(
                id: 0,
                header: "@@ -0,0 +1,\(lineCount) @@",
                oldStart: 0,
                oldCount: 0,
                newStart: 1,
                newCount: lineCount,
                lines: lines
            )
        ],
        state: .textual
    )
    return DiffStackFile(
        id: path,
        path: path,
        originalPath: nil,
        status: .modified,
        statusLabel: "M",
        isExpanded: true,
        isFocused: false,
        isReviewed: false,
        showsWholeFile: false,
        isLoadingWholeFile: false,
        canToggleWholeFile: false,
        canOpenWorkingFile: false,
        canOpenInVisualStudioCode: false,
        canApplyPrimaryAction: false,
        canDiscard: false,
        isMutationEnabled: false,
        mutationSnapshotID: nil,
        contextGaps: [],
        mutationMode: nil,
        diff: diff,
        imageDiff: nil
    )
}

@Test @MainActor func flingSubstepperSmoothsLowRateWheelBurstsAt165HzWhileKeepingSingleNotchImmediate() {
    _ = NSApplication.shared

    let scrollView = DiffStackScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 300))
    let largeFile = makeTestDiffFile(path: "Large.swift", lineCount: 160)
    scrollView.display(
        groups: [
            DiffStackGroup(
                id: "working",
                title: "Working",
                emptyMessage: "",
                isExpanded: true,
                files: [largeFile]
            )
        ],
        layout: .unified,
        scrollTarget: nil
    )
    scrollView.layoutSubtreeIfNeeded()

    // 1. 慢速单格滚轮刻度保持 1:1 立即响应，不启动平滑插值。
    let singleNotchHandled = scrollView.receiveVerticalScrollInput(
        stepDeltaY: 22.7,
        phase: [],
        momentumPhase: [],
        now: 10.0,
        screenMaxFPS: 165
    )
    #expect(!singleNotchHandled)
    #expect(!scrollView.isFlingSubstepping)

    // 2. 120Hz 触控板手指直接拖拽、快速大步长滑动与惯性阶段保持原生跟手，不误入鼠标滚轮步进器。
    #expect(
        !scrollView.receiveVerticalScrollInput(
            stepDeltaY: 96,
            phase: .began,
            momentumPhase: [],
            now: 11.0,
            screenMaxFPS: 165
        )
    )
    #expect(
        !scrollView.receiveVerticalScrollInput(
            stepDeltaY: 120,
            phase: .changed,
            momentumPhase: [],
            now: 11.0 + 1.0 / 120.0,
            screenMaxFPS: 165
        )
    )
    #expect(
        !scrollView.receiveVerticalScrollInput(
            stepDeltaY: 0,
            phase: .ended,
            momentumPhase: [],
            now: 11.0 + 2.0 / 120.0,
            screenMaxFPS: 165
        )
    )
    #expect(
        !scrollView.receiveVerticalScrollInput(
            stepDeltaY: 85,
            phase: [],
            momentumPhase: .changed,
            now: 11.0 + 3.0 / 120.0,
            screenMaxFPS: 165
        )
    )
    #expect(!scrollView.isFlingSubstepping)

    // 3. 30Hz 大步长滚轮 fling（每次 90pt，共 12 次 = 1080pt）拆解到每个 165Hz vsync 连续推进。
    let vsyncDt = 1.0 / 165.0
    let startTime = 20.0
    let wheelEvents: [(CFTimeInterval, CGFloat)] = (0..<12).map { index in
        (startTime + Double(index) * 0.033, 90.0)
    }
    var eventCursor = 0
    var frameSteps: [CGFloat] = []

    for frame in 0..<140 {
        let now = startTime + Double(frame) * vsyncDt
        let beforeY = scrollView.contentView.bounds.minY
        var kickedOnReceive = false
        while eventCursor < wheelEvents.count, wheelEvents[eventCursor].0 <= now + 1e-9 {
            let wasSubstepping = scrollView.isFlingSubstepping
            let handled = scrollView.receiveVerticalScrollInput(
                stepDeltaY: wheelEvents[eventCursor].1,
                phase: [],
                momentumPhase: [],
                now: wheelEvents[eventCursor].0,
                screenMaxFPS: 165
            )
            #expect(handled)
            if !wasSubstepping {
                kickedOnReceive = true
            }
            eventCursor += 1
        }
        if !kickedOnReceive, scrollView.isFlingSubstepping {
            _ = scrollView.stepFlingSubstepper(at: now, nominalFrameDuration: vsyncDt)
        }
        let moved = scrollView.contentView.bounds.minY - beforeY
        if scrollView.isFlingSubstepping || moved > 0 {
            frameSteps.append(moved)
        }
    }

    // Fling 主体期间（前 60 个 165Hz vsync）每一帧都有连续正位移，没有 0pt 冻结断帧，且单帧步长远小于原始 90pt 跳变。
    #expect(frameSteps.count >= 65)
    for step in frameSteps.prefix(60) {
        #expect(step > 1.0)
        #expect(step < 45.0)
    }
    #expect(abs(scrollView.contentView.bounds.minY - 1_080) < 0.5)
    #expect(!scrollView.isFlingSubstepping)

    // 4. 蓝牙滚轮包间隔抖动（10ms 双包簇紧跟 55ms 长空窗）在 165Hz 下也不得中途耗尽出现 0pt 断流。
    scrollView.contentView.scroll(to: .zero)
    scrollView.reflectScrolledClipView(scrollView.contentView)
    let bleStart = 25.0
    let bleOffsets: [CFTimeInterval] = [0.000, 0.010, 0.065, 0.075, 0.130, 0.140, 0.195, 0.205, 0.260]
    let bleEvents: [(CFTimeInterval, CGFloat)] = bleOffsets.map { (bleStart + $0, 72.0) }
    var bleCursor = 0
    var bleActiveSteps: [CGFloat] = []

    for frame in 0..<130 {
        let now = bleStart + Double(frame) * vsyncDt
        let beforeY = scrollView.contentView.bounds.minY
        var kickedOnReceive = false
        while bleCursor < bleEvents.count, bleEvents[bleCursor].0 <= now + 1e-9 {
            let wasSubstepping = scrollView.isFlingSubstepping
            let handled = scrollView.receiveVerticalScrollInput(
                stepDeltaY: bleEvents[bleCursor].1,
                phase: [],
                momentumPhase: [],
                now: bleEvents[bleCursor].0,
                screenMaxFPS: 165
            )
            #expect(handled)
            if !wasSubstepping {
                kickedOnReceive = true
            }
            bleCursor += 1
        }
        if !kickedOnReceive, scrollView.isFlingSubstepping {
            _ = scrollView.stepFlingSubstepper(at: now, nominalFrameDuration: vsyncDt)
        }
        let moved = scrollView.contentView.bounds.minY - beforeY
        if now <= bleStart + 0.260 {
            bleActiveSteps.append(moved)
        }
    }

    #expect(bleActiveSteps.count >= 40)
    for step in bleActiveSteps {
        #expect(step > 0.5)
    }
    #expect(abs(scrollView.contentView.bounds.minY - 648) < 0.5)
    #expect(!scrollView.isFlingSubstepping)

    // 5. 中途点击或取消立即刹停，不残留额外滑行。
    _ = scrollView.receiveVerticalScrollInput(
        stepDeltaY: 95,
        phase: [],
        momentumPhase: [],
        now: 30.0,
        screenMaxFPS: 165
    )
    #expect(scrollView.isFlingSubstepping)
    let stoppedY = scrollView.contentView.bounds.minY
    scrollView.cancelFlingSubstepping()
    #expect(!scrollView.isFlingSubstepping)
    _ = scrollView.stepFlingSubstepper(at: 30.0 + vsyncDt, nominalFrameDuration: vsyncDt)
    #expect(scrollView.contentView.bounds.minY == stoppedY)
}

@Test func loadWorktreeMarksNoCheckoutWorktreeUnavailableUntilIndexIsInitialized() async throws {
    let tempRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("AgentGitTests.UninitializedWorktree.\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let service = GitRepositoryService()

    // 尚未产生任何提交的全新仓库没有 .git/index 属于正常情况，仍应返回可用状态。
    let unbornURL = tempRoot.appendingPathComponent("unborn", isDirectory: true)
    try FileManager.default.createDirectory(at: unbornURL, withIntermediateDirectories: true)
    try runGit(["init", "-q"], in: unbornURL)
    let unbornProject = try await service.loadProject(at: unbornURL)
    let unbornSnapshot = try #require(unbornProject.worktrees.first)
    #expect(unbornSnapshot.hasUsableState)

    // 主仓提交文件后，通过 `--no-checkout` 加工作区文件拷贝模拟克隆中途尚未生成 index 的窗口。
    let repoURL = tempRoot.appendingPathComponent("repo", isDirectory: true)
    let worktreeURL = tempRoot.appendingPathComponent("wt", isDirectory: true)
    try FileManager.default.createDirectory(
        at: repoURL.appendingPathComponent("Sources", isDirectory: true),
        withIntermediateDirectories: true
    )
    try runGit(["init", "-q"], in: repoURL)
    try runGit(["config", "user.name", "Test User"], in: repoURL)
    try runGit(["config", "user.email", "test@example.com"], in: repoURL)
    let sourceFile = repoURL.appendingPathComponent("Sources/App.swift")
    try "let ready = true\n".write(to: sourceFile, atomically: true, encoding: .utf8)
    try runGit(["add", "Sources/App.swift"], in: repoURL)
    try runGit(["commit", "-qm", "Initial commit"], in: repoURL)

    try runGit(["worktree", "add", "--no-checkout", worktreeURL.path, "-b", "feature-wt", "-q"], in: repoURL)
    try FileManager.default.createDirectory(
        at: worktreeURL.appendingPathComponent("Sources", isDirectory: true),
        withIntermediateDirectories: true
    )
    try FileManager.default.copyItem(
        at: sourceFile,
        to: worktreeURL.appendingPathComponent("Sources/App.swift")
    )

    let midCheckoutProject = try await service.loadProject(at: repoURL)
    let midCheckoutSnapshot = try #require(
        midCheckoutProject.worktrees.first {
            $0.worktree.rootURL.standardizedFileURL == worktreeURL.standardizedFileURL
        }
    )
    #expect(!midCheckoutSnapshot.hasUsableState)
    #expect(midCheckoutSnapshot.refreshedAt == nil)
    #expect(midCheckoutSnapshot.status.changes.isEmpty)
    #expect(midCheckoutSnapshot.eventWatchURLs.count >= 2)

    // 未就绪的非活跃 worktree 只监听 Git 元数据目录，写完 index 后能收到元数据变更通知。
    let watchIndex = RepositoryWatchIndex(
        projects: [ProjectState(project: midCheckoutProject.project, snapshot: midCheckoutProject)],
        activeWorkingTreeIDs: [repoURL.standardizedFileURL.path]
    )
    #expect(!Set(watchIndex.watchedPaths).contains(worktreeURL.standardizedFileURL.path))
    let adminGitDir = try #require(
        midCheckoutSnapshot.eventWatchURLs.first {
            $0.standardizedFileURL.path.contains("/.git/worktrees/")
        }
    )
    let indexImpact = watchIndex.impact(
        for: [adminGitDir.appendingPathComponent("index").path]
    )
    #expect(indexImpact.metadataWorktreeIDs.contains(midCheckoutSnapshot.id))

    // `git reset` 写回 index 后再次加载，应恢复为干净可用状态。
    try runGit(["reset", "-q"], in: worktreeURL)
    let readySnapshot = await service.loadWorktree(midCheckoutSnapshot.worktree)
    #expect(readySnapshot.hasUsableState)
    #expect(readySnapshot.errorMessage == nil)
    #expect(readySnapshot.status.changes.isEmpty)
}

@Test @MainActor func integratedReviewWorkspaceLayoutsLargePendingFileSnapshotWithoutQuadraticStall() throws {
    _ = NSApplication.shared

    let suiteName = "AgentGitTests.LargePending.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let rootURL = URL(fileURLWithPath: "/repos/large-worktree")
    let worktree = GitWorktree(
        rootURL: rootURL,
        headOID: "1111111111111111111111111111111111111111",
        branchRef: "refs/heads/main",
        isBare: false,
        isDetached: false,
        lockedReason: nil,
        prunableReason: nil
    )

    var changes: [GitFileChange] = []
    changes.reserveCapacity(10_000)
    for index in 0..<5_000 {
        let folder = "Module\(index / 100)"
        changes.append(
            GitFileChange(
                path: "\(folder)/Tracked\(index).swift",
                originalPath: nil,
                indexStatus: "D",
                worktreeStatus: ".",
                kind: .ordinary
            )
        )
        changes.append(
            GitFileChange(
                path: "\(folder)/Untracked\(index).swift",
                originalPath: nil,
                indexStatus: "?",
                worktreeStatus: "?",
                kind: .untracked
            )
        )
    }

    let snapshot = GitWorktreeSnapshot(
        worktree: worktree,
        status: GitStatusSnapshot(
            changes: changes,
            branch: nil,
            headOID: worktree.headOID,
            branchHead: "main"
        ),
        diffStat: .zero,
        lastActivityAt: Date(timeIntervalSince1970: 1_000),
        refreshedAt: Date(timeIntervalSince1970: 1_000),
        errorMessage: nil
    )

    let model = AppModel(defaults: defaults)
    let start = ContinuousClock.now
    let workspace = IntegratedReviewWorkspace(snapshot: snapshot)
        .environment(model)
    let host = NSHostingView(rootView: workspace)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 800),
        styleMask: [.titled, .resizable],
        backing: .buffered,
        defer: false
    )
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    let elapsed = ContinuousClock.now - start

    #expect(elapsed < .seconds(3))
}

private func runGit(_ arguments: [String], in directory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = directory
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        struct GitCommandError: LocalizedError {
            let message: String
            var errorDescription: String? { message }
        }
        throw GitCommandError(message: output)
    }
}
