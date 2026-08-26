import AgentGitCore
import AppKit
import XCTest
@testable import AgentGitApp

@MainActor
final class DiffStackViewTests: XCTestCase {
    func testSwitchingLayoutRebuildsUnifiedRowsIntoPairedRows() throws {
        let scrollView = makeScrollView()
        let groups = [makeGroup()]

        scrollView.display(groups: groups, layout: .unified, scrollTarget: nil)
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        XCTAssertEqual(tableView.numberOfRows, 7)

        scrollView.display(groups: groups, layout: .sideBySide, scrollTarget: nil)
        XCTAssertEqual(tableView.numberOfRows, 6)

        let pairedCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 4, makeIfNecessary: true)
        )
        pairedCell.frame = NSRect(x: 0, y: 0, width: 1_000, height: 20)
        pairedCell.layoutSubtreeIfNeeded()

        XCTAssertEqual(pairedCell.subviews.count, 2)
        XCTAssertEqual(pairedCell.subviews[0].frame.width, 500, accuracy: 0.5)
        XCTAssertEqual(pairedCell.subviews[1].frame.minX, 501, accuracy: 0.5)
    }

    func testEveryLayoutUsesViewportWidthWithoutHorizontalScrollAxis() throws {
        for layout in DiffLayoutMode.allCases {
            let scrollView = makeScrollView()
            scrollView.frame = NSRect(x: 0, y: 0, width: 500, height: 600)
            scrollView.display(groups: [makeGroup()], layout: layout, scrollTarget: nil)
            scrollView.layoutSubtreeIfNeeded()
            let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
            let column = try XCTUnwrap(tableView.tableColumns.first)
            XCTAssertEqual(tableView.effectiveStyle, .inset)
            XCTAssertEqual(
                tableView.frame.width,
                scrollView.contentView.bounds.width,
                accuracy: 0.5
            )
            XCTAssertEqual(
                scrollView.contentView.bounds.width - column.width,
                32,
                accuracy: 0.5
            )
            XCTAssertFalse(scrollView.hasHorizontalScroller)
            XCTAssertTrue(scrollView.usesPredominantAxisScrolling)
            XCTAssertEqual(scrollView.horizontalScrollElasticity, .none)

            let firstCell = try XCTUnwrap(
                tableView.view(atColumn: 0, row: 0, makeIfNecessary: true)
            )
            XCTAssertEqual(firstCell.frame.minX, 16, accuracy: 0.5)
            XCTAssertEqual(
                tableView.frame.width - firstCell.frame.maxX,
                16,
                accuracy: 0.5
            )
            XCTAssertGreaterThanOrEqual(tableView.rect(ofRow: 0).minY, 8)

            scrollView.frame = NSRect(x: 0, y: 0, width: 760, height: 600)
            scrollView.layoutSubtreeIfNeeded()
            XCTAssertEqual(
                tableView.frame.width,
                scrollView.contentView.bounds.width,
                accuracy: 0.5
            )
            XCTAssertEqual(
                scrollView.contentView.bounds.width - column.width,
                32,
                accuracy: 0.5
            )

            let event = try makeScrollWheelEvent(horizontalDelta: 100, verticalDelta: 0)
            scrollView.scrollWheel(with: event)
            XCTAssertEqual(scrollView.contentView.bounds.minX, 0, accuracy: 0.5)
        }
    }

    func testOnlyVerticallyDominantWheelEventsEnterScrollView() {
        XCTAssertFalse(
            DiffStackScrollView.shouldForwardScrollWheel(
                horizontalDelta: 100,
                verticalDelta: 0
            )
        )
        XCTAssertFalse(
            DiffStackScrollView.shouldForwardScrollWheel(
                horizontalDelta: 100,
                verticalDelta: 8
            )
        )
        XCTAssertTrue(
            DiffStackScrollView.shouldForwardScrollWheel(
                horizontalDelta: 8,
                verticalDelta: 100
            )
        )
        XCTAssertTrue(
            DiffStackScrollView.shouldForwardScrollWheel(
                horizontalDelta: 0,
                verticalDelta: 0
            )
        )
    }

    func testBindingNewPageClearsAnyHorizontalDocumentOffsetImmediately() {
        let scrollView = makeScrollView()
        scrollView.display(groups: [makeGroup()], layout: .sideBySide, scrollTarget: nil)
        scrollView.layoutSubtreeIfNeeded()
        let store = ReviewStateStore()
        let previousKey = ReviewStateKey(worktreeID: "/previous", context: .pending)
        let nextKey = ReviewStateKey(worktreeID: "/next", context: .pending)

        scrollView.bind(store: store, key: previousKey)
        scrollView.contentView.scroll(to: NSPoint(x: 60, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        XCTAssertEqual(scrollView.contentView.bounds.minX, 60, accuracy: 0.5)

        store.saveScrollOffset(100, for: nextKey)
        scrollView.bind(store: store, key: nextKey)
        XCTAssertEqual(scrollView.contentView.bounds.minX, 0, accuracy: 0.5)
        XCTAssertEqual(scrollView.contentView.bounds.minY, 0, accuracy: 0.5)
    }

    func testGroupAndFileHeadersStickAsOneStack() throws {
        let scrollView = makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 80)
        scrollView.display(groups: [makeGroup()], layout: .sideBySide, scrollTarget: nil)
        scrollView.layoutSubtreeIfNeeded()

        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 60))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        scrollView.layoutSubtreeIfNeeded()

        let sticky = try XCTUnwrap(
            descendants(of: scrollView).first {
                String(reflecting: type(of: $0)).contains("DiffStickyClipView")
            }
        )
        XCTAssertFalse(sticky.isHidden)
        XCTAssertEqual(sticky.frame.height, 68, accuracy: 0.5)

        let visibleHeaders = sticky.subviews
            .filter { !$0.isHidden }
            .sorted { $0.frame.minY < $1.frame.minY }
        XCTAssertEqual(visibleHeaders.count, 2)
        XCTAssertTrue(visibleHeaders.allSatisfy(\.clipsToBounds))
        XCTAssertEqual(visibleHeaders[0].frame.minY, 0, accuracy: 0.5)
        XCTAssertEqual(visibleHeaders[0].frame.height, 30, accuracy: 0.5)
        XCTAssertEqual(visibleHeaders[1].frame.minY, 30, accuracy: 0.5)
        XCTAssertEqual(visibleHeaders[1].frame.height, 38, accuracy: 0.5)

        let labels = descendants(of: sticky)
            .compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(labels.contains("WORKING  ·  1"))
        XCTAssertTrue(labels.contains { $0.contains("Sample.swift") })
    }

    func testTabAndShiftTabNavigateHunksBelowStickyHeaders() throws {
        let scrollView = makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 100)
        scrollView.display(
            groups: [makeGroup(includesSecondHunk: true)],
            layout: .unified,
            scrollTarget: nil
        )
        scrollView.layoutSubtreeIfNeeded()
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)

        tableView.keyDown(with: try makeTabEvent())
        XCTAssertEqual(tableView.selectedRow, 2)

        tableView.keyDown(with: try makeTabEvent())
        XCTAssertEqual(tableView.selectedRow, 7)
        XCTAssertEqual(
            tableView.rect(ofRow: 7).minY - scrollView.contentView.bounds.minY,
            68,
            accuracy: 0.5
        )

        tableView.keyDown(with: try makeTabEvent(modifiers: .shift))
        XCTAssertEqual(tableView.selectedRow, 2)
        XCTAssertEqual(
            tableView.rect(ofRow: 2).minY - scrollView.contentView.bounds.minY,
            68,
            accuracy: 0.5
        )
    }

    func testVisibleUnifiedCellCombinesSyntaxAndInlineHighlighting() throws {
        let scrollView = makeScrollView()
        scrollView.display(groups: [makeGroup()], layout: .unified, scrollTarget: nil)
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        let cell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 4, makeIfNecessary: true)
        )
        let content = try XCTUnwrap(
            cell.subviews.compactMap { $0 as? NSTextField }
                .first { $0.stringValue == "let newValue = 2" }
        )
        XCTAssertFalse(try XCTUnwrap(content.cell).isScrollable)

        let text = content.attributedStringValue
        let keywordColor = try XCTUnwrap(
            text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        )
        XCTAssertNotEqual(keywordColor, NSColor.labelColor)

        let changedRange = try XCTUnwrap(
            makeGroup().files[0].diff?.hunks[0].lines[1].inlineRanges.first
        )
        XCTAssertNotNil(
            text.attribute(
                .backgroundColor,
                at: changedRange.location,
                effectiveRange: nil
            ) as? NSColor
        )
    }

    func testPendingFileAndHunkExposeDirectActions() throws {
        let scrollView = makeScrollView()
        var fileAction: GitPendingSelectionAction?
        var hunkAction: GitPendingSelectionAction?
        scrollView.onFileAction = { _, action in fileAction = action }
        scrollView.onSelectionAction = { _, _, action in hunkAction = action }
        scrollView.display(groups: [makeGroup()], layout: .unified, scrollTarget: nil)
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)

        let fileCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 1, makeIfNecessary: true)
        )
        let fileButtons = fileCell.subviews.compactMap { $0 as? NSButton }
        try XCTUnwrap(fileButtons.first { $0.title == "Stage" }).performClick(nil)
        XCTAssertEqual(fileAction, .stage)
        XCTAssertNotNil(fileButtons.first { $0.title == "Discard" })

        let hunkCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 2, makeIfNecessary: true)
        )
        let hunkButtons = hunkCell.subviews.compactMap { $0 as? NSButton }
        try XCTUnwrap(hunkButtons.first { $0.title == "Stage Hunk" }).performClick(nil)
        XCTAssertEqual(hunkAction, .stage)
        XCTAssertNotNil(hunkButtons.first { $0.title == "Discard" })
    }

    func testChangedLineContextMenuExposesLineActions() {
        let scrollView = makeScrollView()
        scrollView.display(groups: [makeGroup()], layout: .unified, scrollTarget: nil)

        let menu = scrollView.contextMenu(
            clickedRow: 4,
            selectedRows: IndexSet(integersIn: 3...4)
        )
        let titles = menu.items.map(\.title)

        XCTAssertTrue(titles.contains("Stage Selected Lines"))
        XCTAssertTrue(titles.contains("Discard Selected Lines…"))
    }

    func testSideBySideLineActionCarriesBothChangedLineIDs() throws {
        let scrollView = makeScrollView()
        var receivedIDs: Set<GitDiffLine.ID> = []
        scrollView.onSelectionAction = { _, lineIDs, _ in
            receivedIDs = lineIDs
        }
        scrollView.display(groups: [makeGroup()], layout: .sideBySide, scrollTarget: nil)

        let menu = scrollView.contextMenu(
            clickedRow: 3,
            selectedRows: IndexSet(integer: 3)
        )
        let stageIndex = try XCTUnwrap(
            menu.items.firstIndex { $0.title == "Stage Selected Lines" }
        )
        menu.performActionForItem(at: stageIndex)

        XCTAssertEqual(receivedIDs, [0, 1])
    }

    func testRendersSideBySideSnapshotOffscreen() throws {
        let scrollView = makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 1_200, height: 420)
        scrollView.display(groups: [makeGroup()], layout: .sideBySide, scrollTarget: nil)
        scrollView.layoutSubtreeIfNeeded()
        scrollView.displayIfNeeded()

        let bitmap = try XCTUnwrap(
            scrollView.bitmapImageRepForCachingDisplay(in: scrollView.bounds)
        )
        scrollView.cacheDisplay(in: scrollView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1_000)

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentGitDiffStack-side-by-side.png")
        try png.write(to: output)
        print("AgentGit offscreen snapshot: \(output.path)")
    }

    private func makeScrollView() -> DiffStackScrollView {
        let scrollView = DiffStackScrollView(
            frame: NSRect(x: 0, y: 0, width: 1_000, height: 600)
        )
        scrollView.layoutSubtreeIfNeeded()
        return scrollView
    }

    private func makeScrollWheelEvent(
        horizontalDelta: Int32,
        verticalDelta: Int32
    ) throws -> NSEvent {
        let event = try XCTUnwrap(
            CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: verticalDelta,
                wheel2: horizontalDelta,
                wheel3: 0
            )
        )
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }

    private func makeTabEvent(
        modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\t",
                charactersIgnoringModifiers: "\t",
                isARepeat: false,
                keyCode: 48
            )
        )
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private func makeGroup(includesSecondHunk: Bool = false) -> DiffStackGroup {
        let change = GitFileChange(
            path: "Sources/Sample.swift",
            originalPath: nil,
            indexStatus: ".",
            worktreeStatus: "M",
            kind: .ordinary
        )
        let rawLines = [
            GitDiffLine(
                id: 0,
                kind: .deletion,
                oldLineNumber: 1,
                newLineNumber: nil,
                content: "let oldValue = 1"
            ),
            GitDiffLine(
                id: 1,
                kind: .addition,
                oldLineNumber: nil,
                newLineNumber: 1,
                content: "let newValue = 2"
            ),
            GitDiffLine(
                id: 2,
                kind: .deletion,
                oldLineNumber: 2,
                newLineNumber: nil,
                content: "return oldValue"
            ),
            GitDiffLine(
                id: 3,
                kind: .context,
                oldLineNumber: 3,
                newLineNumber: 2,
                content: "// keep"
            )
        ]
        let lines = InlineDiffCalculator.annotate(rawLines)
        var hunks = [
            GitDiffHunk(
                id: 0,
                header: "@@ -1,3 +1,2 @@",
                oldStart: 1,
                oldCount: 3,
                newStart: 1,
                newCount: 2,
                lines: lines
            )
        ]
        if includesSecondHunk {
            hunks.append(
                GitDiffHunk(
                    id: 1,
                    header: "@@ -10,1 +10,1 @@",
                    oldStart: 10,
                    oldCount: 1,
                    newStart: 10,
                    newCount: 1,
                    lines: [
                        GitDiffLine(
                            id: 10,
                            kind: .deletion,
                            oldLineNumber: 10,
                            newLineNumber: nil,
                            content: "let oldFlag = false"
                        ),
                        GitDiffLine(
                            id: 11,
                            kind: .addition,
                            oldLineNumber: nil,
                            newLineNumber: 10,
                            content: "let newFlag = true"
                        )
                    ]
                )
            )
        }
        let diff = GitFileDiff(
            change: change,
            scope: .working,
            hunks: hunks,
            state: .textual
        )
        return DiffStackGroup(
            id: "working",
            title: "Working",
            emptyMessage: "No changes",
            isExpanded: true,
            files: [
                DiffStackFile(
                    id: "sample",
                    path: change.path,
                    status: .modified,
                    statusLabel: "M",
                    isExpanded: true,
                    isFocused: false,
                    mutationMode: .working,
                    diff: diff
                )
            ]
        )
    }
}
