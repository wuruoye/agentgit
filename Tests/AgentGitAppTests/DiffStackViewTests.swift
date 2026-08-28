import AgentGitCore
import AppKit
import XCTest
@testable import AgentGitApp

@MainActor
final class DiffStackViewTests: XCTestCase {
    func testFileHeaderButtonsReceiveClicksBeforeRowDisclosure() {
        XCTAssertFalse(shouldToggleDiffRow(for: NSButton()))
        XCTAssertTrue(shouldToggleDiffRow(for: NSTextField()))
    }

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

        XCTAssertEqual(pairedCell.subviews.count, 3)
        XCTAssertEqual(pairedCell.subviews[0].frame.width, 500, accuracy: 0.01)
        XCTAssertEqual(pairedCell.subviews[1].frame.width, 500, accuracy: 0.01)
        XCTAssertEqual(pairedCell.subviews[1].frame.minX, 500, accuracy: 0.01)
        XCTAssertEqual(pairedCell.subviews[2].frame.midX, 500, accuracy: 0.01)
    }

    func testRenameHeaderShowsOldAndNewPaths() throws {
        let scrollView = makeScrollView()
        let group = makeGroup(
            path: "Sources/NewName.swift",
            originalPath: "Legacy/OldName.swift",
            status: .renamed,
            statusLabel: "R"
        )
        scrollView.display(groups: [group], layout: .unified, scrollTarget: nil)
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        let fileCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 1, makeIfNecessary: true)
        )
        let labels = descendants(of: fileCell)
            .compactMap { ($0 as? NSTextField)?.stringValue }

        XCTAssertTrue(
            labels.contains("OldName.swift → NewName.swift · Legacy → Sources")
        )
        XCTAssertEqual(fileCell.toolTip, "Legacy/OldName.swift → Sources/NewName.swift")
    }

    func testMetadataOnlyDiffShowsGitSummaryInReviewStream() throws {
        let scrollView = makeScrollView()
        let summary = "old mode 100644 · new mode 100755"
        scrollView.display(
            groups: [makeMetadataGroup(summary: summary)],
            layout: .unified,
            scrollTarget: nil
        )
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        XCTAssertEqual(tableView.numberOfRows, 3)
        let noteCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 2, makeIfNecessary: true)
        )
        let labels = descendants(of: noteCell)
            .compactMap { ($0 as? NSTextField)?.stringValue }

        XCTAssertTrue(labels.contains(summary))
    }

    func testEmptyGroupMessageUpdatesWhenFilterMeaningChanges() throws {
        let scrollView = makeScrollView()
        func group(message: String) -> DiffStackGroup {
            DiffStackGroup(
                id: "working",
                title: "Working",
                emptyMessage: message,
                isExpanded: false,
                files: []
            )
        }
        scrollView.display(
            groups: [group(message: "No working changes")],
            layout: .unified,
            scrollTarget: nil
        )
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        XCTAssertEqual(tableView.numberOfRows, 2)

        scrollView.display(
            groups: [group(message: "No matching working files")],
            layout: .unified,
            scrollTarget: nil
        )
        let noteCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 1, makeIfNecessary: true)
        )
        let labels = descendants(of: noteCell).compactMap {
            ($0 as? NSTextField)?.stringValue
        }

        XCTAssertTrue(labels.contains("No matching working files"))
        XCTAssertFalse(labels.contains("No working changes"))
    }

    func testPendingReviewOmitsEmptyGroups() {
        let working = makeGroup()
        let staged = DiffStackGroup(
            id: "staged",
            title: "Staged",
            emptyMessage: "No staged changes",
            isExpanded: false,
            files: []
        )

        XCTAssertEqual(
            nonEmptyDiffStackGroups([working, staged]).map(\.id),
            [working.id]
        )
    }

    func testImageDiffUsesEqualBeforeAndAfterPanes() async throws {
        let oldImageData = try XCTUnwrap(
            Data(
                base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
            )
        )
        let newImageData = try XCTUnwrap(
            Data(
                base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR4nGNgYAAAAAMAASsJTYQAAAAASUVORK5CYII="
            )
        )
        let scrollView = makeScrollView()
        scrollView.display(
            groups: [makeImageGroup(oldImageData: oldImageData, newImageData: newImageData)],
            layout: .sideBySide,
            scrollTarget: nil
        )
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        XCTAssertEqual(tableView.numberOfRows, 3)
        let imageCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 2, makeIfNecessary: true)
        )
        imageCell.frame = NSRect(x: 0, y: 0, width: 1_001, height: 360)
        imageCell.layoutSubtreeIfNeeded()
        let panes = descendants(of: imageCell).filter {
            ["diff-image-before", "diff-image-after"].contains($0.identifier?.rawValue)
        }.sorted { $0.frame.minX < $1.frame.minX }
        XCTAssertEqual(panes.count, 2)
        XCTAssertEqual(panes[0].frame.width, panes[1].frame.width, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(panes[0].frame.minX, 12)
        XCTAssertGreaterThanOrEqual(imageCell.bounds.maxX - panes[1].frame.maxX, 12)

        var imageViews: [NSImageView] = []
        for _ in 0..<100 {
            imageViews = descendants(of: imageCell).compactMap { view -> NSImageView? in
                guard view.identifier?.rawValue == "diff-image-content" else {
                    return nil
                }
                return view as? NSImageView
            }
            if imageViews.count == 2, imageViews.allSatisfy({ $0.image != nil }) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(imageViews.count, 2)
        XCTAssertTrue(imageViews.allSatisfy { $0.image != nil })
        XCTAssertEqual(
            Set(imageViews.compactMap { $0.accessibilityLabel() }),
            ["Before image", "After image"]
        )
        XCTAssertTrue(
            imageViews.compactMap { $0.accessibilityValue() as? String }
                .allSatisfy {
                    $0.contains("Assets/icon.png") && $0.contains("1×1")
                }
        )
    }

    func testImagePreviewPausesInBackgroundAndResumesWhenActive() async throws {
        let oldImageData = try XCTUnwrap(
            Data(
                base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
            )
        )
        let newImageData = try XCTUnwrap(
            Data(
                base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR4nGNgYAAAAAMAASsJTYQAAAAASUVORK5CYII="
            )
        )
        let scrollView = makeScrollView()
        scrollView.isApplicationActive = false
        scrollView.display(
            groups: [makeImageGroup(oldImageData: oldImageData, newImageData: newImageData)],
            layout: .sideBySide,
            scrollTarget: nil
        )
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        let imageCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 2, makeIfNecessary: true)
        )
        imageCell.layoutSubtreeIfNeeded()
        let pausedLabels = descendants(of: imageCell).compactMap {
            ($0 as? NSTextField)?.stringValue
        }
        let pausedImages = descendants(of: imageCell).compactMap { view -> NSImage? in
            guard view.identifier?.rawValue == "diff-image-content" else {
                return nil
            }
            return (view as? NSImageView)?.image
        }
        XCTAssertEqual(
            pausedLabels.count(where: { $0 == "Preview paused in background" }),
            2
        )
        XCTAssertTrue(pausedImages.isEmpty)

        scrollView.isApplicationActive = true
        var resumedImages: [NSImage] = []
        for _ in 0..<100 {
            resumedImages = descendants(of: imageCell).compactMap { view -> NSImage? in
                guard view.identifier?.rawValue == "diff-image-content" else {
                    return nil
                }
                return (view as? NSImageView)?.image
            }
            if resumedImages.count == 2 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(resumedImages.count, 2)
    }

    func testEveryLayoutKeepsTheOuterDocumentAtViewportWidth() throws {
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

    func testNearLimitDiffBuildsWithinInteractiveBudgetAndKeepsHeaderUpdatesLightweight() {
        let change = GitFileChange(
            path: "Sources/LargeGenerated.swift",
            originalPath: nil,
            indexStatus: ".",
            worktreeStatus: "M",
            kind: .ordinary
        )
        let lines = (0..<40_000).map { index in
            GitDiffLine(
                id: index,
                kind: index.isMultiple(of: 2) ? .deletion : .addition,
                oldLineNumber: index.isMultiple(of: 2) ? index + 1 : nil,
                newLineNumber: index.isMultiple(of: 2) ? nil : index + 1,
                content: "let generatedValue\(index) = \(index)"
            )
        }
        let diff = GitFileDiff(
            change: change,
            scope: .working,
            hunks: [
                GitDiffHunk(
                    id: 0,
                    header: "@@ -1,20000 +1,20000 @@ generatedValues",
                    sectionHeading: "generatedValues",
                    oldStart: 1,
                    oldCount: 20_000,
                    newStart: 1,
                    newCount: 20_000,
                    lines: lines
                )
            ],
            state: .textual
        )
        func group(isReviewed: Bool) -> DiffStackGroup {
            DiffStackGroup(
                id: "working",
                title: "Working",
                emptyMessage: "No changes",
                isExpanded: true,
                files: [
                    DiffStackFile(
                        id: "large",
                        path: change.path,
                        originalPath: nil,
                        status: .modified,
                        statusLabel: "M",
                        isExpanded: true,
                        isFocused: false,
                        isReviewed: isReviewed,
                        showsWholeFile: false,
                        isLoadingWholeFile: false,
                        canToggleWholeFile: true,
                        canOpenWorkingFile: true,
                        canOpenInVisualStudioCode: true,
                        canApplyPrimaryAction: true,
                        canDiscard: true,
                        isMutationEnabled: true,
                        contextGaps: [],
                        mutationMode: .working,
                        diff: diff,
                        imageDiff: nil
                    )
                ]
            )
        }
        let scrollView = makeScrollView()
        let initialStart = ContinuousClock.now
        scrollView.display(
            groups: [group(isReviewed: false)],
            layout: .unified,
            scrollTarget: nil
        )
        let initialDuration = initialStart.duration(to: .now)

        XCTAssertLessThan(initialDuration, .seconds(1))
        XCTAssertEqual(scrollView.rowRebuildCount, 1)
        let headerStart = ContinuousClock.now
        scrollView.display(
            groups: [group(isReviewed: true)],
            layout: .unified,
            scrollTarget: nil
        )
        let headerDuration = headerStart.duration(to: .now)

        XCTAssertLessThan(headerDuration, .milliseconds(250))
        XCTAssertEqual(scrollView.rowRebuildCount, 1)
    }

    func testNarrowFileHeaderKeepsMutationButtonsInsideViewport() throws {
        let scrollView = makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 640, height: 300)
        scrollView.display(
            groups: [
                makeGroup(
                    path: "Sources/Deeply/Nested/LongChangedFileNameThatMustTruncate.swift"
                )
            ],
            layout: .sideBySide,
            scrollTarget: nil
        )
        scrollView.layoutSubtreeIfNeeded()
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        let fileCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 1, makeIfNecessary: true)
        )
        fileCell.layoutSubtreeIfNeeded()
        let buttons = descendants(of: fileCell).compactMap { $0 as? NSButton }
        let stage = try XCTUnwrap(buttons.first { $0.title == "Stage" })
        let discard = try XCTUnwrap(buttons.first { $0.title == "Discard" })
        let menu = try XCTUnwrap(buttons.first {
            $0.identifier?.rawValue == "file-actions-menu"
        })
        let title = try XCTUnwrap(
            descendants(of: fileCell).compactMap { $0 as? NSTextField }.first {
                $0.stringValue.contains("LongChangedFileNameThatMustTruncate.swift")
            }
        )

        XCTAssertFalse(stage.isHidden)
        XCTAssertFalse(discard.isHidden)
        XCTAssertGreaterThanOrEqual(stage.frame.minX, fileCell.bounds.minX)
        XCTAssertLessThanOrEqual(stage.frame.maxX, fileCell.bounds.maxX)
        XCTAssertGreaterThanOrEqual(discard.frame.minX, fileCell.bounds.minX)
        XCTAssertLessThanOrEqual(discard.frame.maxX, fileCell.bounds.maxX)
        XCTAssertGreaterThanOrEqual(menu.frame.minX, fileCell.bounds.minX)
        XCTAssertLessThanOrEqual(menu.frame.maxX, fileCell.bounds.maxX)
        XCTAssertEqual(menu.toolTip, "File Actions")
        XCTAssertEqual(menu.accessibilityLabel(), "File Actions")
        XCTAssertEqual(title.lineBreakMode, .byTruncatingMiddle)
    }

    func testLongCodeLineScrollsInsideFixedSideBySidePane() throws {
        let scrollView = makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 760, height: 600)
        let longLine = "let generatedSymbol = "
            + String(repeating: "namespace_component_", count: 40)
        scrollView.display(
            groups: [makeGroup(additionContent: longLine)],
            layout: .sideBySide,
            scrollTarget: nil
        )
        scrollView.layoutSubtreeIfNeeded()

        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        let codeCell = try XCTUnwrap(
            (0..<tableView.numberOfRows).lazy.compactMap { row in
                let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: true)
                return self.descendants(of: cell ?? NSView()).contains {
                    $0.identifier?.rawValue == "diff-new-code-clip"
                } ? cell : nil
            }.first
        )
        codeCell.layoutSubtreeIfNeeded()
        let codeClip = try XCTUnwrap(
            descendants(of: codeCell).first {
                $0.identifier?.rawValue == "diff-new-code-clip"
            }
        )
        let codeContent = try XCTUnwrap(
            descendants(of: codeCell).first {
                $0.identifier?.rawValue == "diff-new-code-content"
            }
        )
        let initialClipFrame = codeClip.frame
        let initialContentX = codeContent.frame.minX
        let tablePoint = tableView.convert(
            NSPoint(x: codeClip.frame.midX, y: codeClip.frame.midY),
            from: codeCell
        )

        XCTAssertTrue(
            scrollView.scrollCodeHorizontally(
                by: -180,
                atTablePoint: tablePoint
            )
        )
        codeCell.layoutSubtreeIfNeeded()

        XCTAssertEqual(scrollView.contentView.bounds.minX, 0, accuracy: 0.5)
        XCTAssertEqual(codeClip.frame, initialClipFrame)
        XCTAssertLessThan(codeContent.frame.minX, initialContentX)
    }

    func testHorizontalScrollPositionIsIndependentForEachHunk() throws {
        let scrollView = makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 760, height: 600)
        let firstLine = "let firstGeneratedSymbol = "
            + String(repeating: "first_namespace_component_", count: 40)
        let secondLine = "let secondGeneratedSymbol = "
            + String(repeating: "second_namespace_component_", count: 40)
        scrollView.display(
            groups: [
                makeGroup(
                    includesSecondHunk: true,
                    additionContent: firstLine,
                    secondAdditionContent: secondLine
                )
            ],
            layout: .sideBySide,
            scrollTarget: nil
        )
        scrollView.layoutSubtreeIfNeeded()
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        let first = try codeRegion(containing: firstLine, in: tableView)
        let second = try codeRegion(containing: secondLine, in: tableView)
        let firstInitialX = first.content.frame.minX
        let secondInitialX = second.content.frame.minX

        XCTAssertTrue(
            scrollView.scrollCodeHorizontally(by: -180, atTablePoint: first.tablePoint)
        )
        first.cell.layoutSubtreeIfNeeded()
        second.cell.layoutSubtreeIfNeeded()
        let firstScrolledX = first.content.frame.minX
        XCTAssertLessThan(firstScrolledX, firstInitialX)
        XCTAssertEqual(second.content.frame.minX, secondInitialX, accuracy: 0.5)

        XCTAssertTrue(
            scrollView.scrollCodeHorizontally(by: -90, atTablePoint: second.tablePoint)
        )
        first.cell.layoutSubtreeIfNeeded()
        second.cell.layoutSubtreeIfNeeded()
        XCTAssertEqual(first.content.frame.minX, firstScrolledX, accuracy: 0.5)
        XCTAssertLessThan(second.content.frame.minX, secondInitialX)
    }

    func testShortHunkDoesNotInheritAnotherHunksScrollableWidth() throws {
        let scrollView = makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 760, height: 600)
        let longLine = "let generatedSymbol = "
            + String(repeating: "namespace_component_", count: 40)
        let shortLine = "let newFlag = true"
        scrollView.display(
            groups: [
                makeGroup(
                    includesSecondHunk: true,
                    additionContent: longLine,
                    secondAdditionContent: shortLine
                )
            ],
            layout: .sideBySide,
            scrollTarget: nil
        )
        scrollView.layoutSubtreeIfNeeded()
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        let long = try codeRegion(containing: longLine, in: tableView)
        let short = try codeRegion(containing: shortLine, in: tableView)
        let shortInitialX = short.content.frame.minX

        XCTAssertTrue(
            scrollView.scrollCodeHorizontally(by: -180, atTablePoint: long.tablePoint)
        )
        XCTAssertTrue(
            scrollView.scrollCodeHorizontally(by: -180, atTablePoint: short.tablePoint)
        )
        long.cell.layoutSubtreeIfNeeded()
        short.cell.layoutSubtreeIfNeeded()

        XCTAssertLessThan(long.content.frame.minX, 0)
        XCTAssertEqual(short.content.frame.minX, shortInitialX, accuracy: 0.5)
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

    func testCodeWidthCountsTabsAndWideCharacters() {
        XCTAssertEqual(DiffStackScrollView.displayedColumnCount("abc"), 5)
        XCTAssertEqual(DiffStackScrollView.displayedColumnCount("ab\tc"), 7)
        XCTAssertEqual(DiffStackScrollView.displayedColumnCount("a中🚀"), 7)
    }

    func testBindingNewPageClearsAnyHorizontalDocumentOffsetImmediately() throws {
        let scrollView = makeScrollView()
        scrollView.display(groups: [makeGroup()], layout: .sideBySide, scrollTarget: nil)
        scrollView.layoutSubtreeIfNeeded()
        let suiteName = "DiffStackViewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = ReviewStateStore(defaults: defaults)
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
        XCTAssertTrue(sticky.isOpaque)
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

        sticky.displayIfNeeded()
        let bitmap = try XCTUnwrap(
            sticky.bitmapImageRepForCachingDisplay(in: sticky.bounds)
        )
        sticky.cacheDisplay(in: sticky.bounds, to: bitmap)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 1, y: 10)).alphaComponent, 1)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 1, y: 45)).alphaComponent, 1)

        let labels = descendants(of: sticky)
            .compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(labels.contains("WORKING · 1"))
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

    func testContextGapBuilderRevealsLinesBeforeNextHunk() throws {
        let compactDiff = try XCTUnwrap(makeGroup(includesSecondHunk: true).files[0].diff)
        let sourceLines = (3...9).map { lineNumber in
            GitDiffLine(
                id: 100 + lineNumber,
                kind: .context,
                oldLineNumber: lineNumber + 1,
                newLineNumber: lineNumber,
                content: "line \(lineNumber)"
            )
        }
        let sourceDiff = GitFileDiff(
            change: compactDiff.change,
            scope: compactDiff.scope,
            hunks: [
                GitDiffHunk(
                    id: 5,
                    header: "@@ -1,10 +1,10 @@",
                    oldStart: 1,
                    oldCount: 10,
                    newStart: 1,
                    newCount: 10,
                    lines: sourceLines
                )
            ],
            state: .textual
        )
        let gapID = "sample:context:0->1"

        let gap = try XCTUnwrap(
            DiffContextGapBuilder.gaps(
                fileID: "sample",
                compactDiff: compactDiff,
                contextSourceDiff: sourceDiff,
                revealedLineCountByGapID: [gapID: 3]
            ).first
        )

        XCTAssertEqual(gap.hiddenLineCount, 4)
        XCTAssertEqual(gap.revealedLines.compactMap(\.newLineNumber), [7, 8, 9])
        XCTAssertEqual(gap.contextRenderID, sourceDiff.renderID)
    }

    func testChangedContextSourceRebuildsRowsWhenLineCountStaysConstant() throws {
        let scrollView = makeScrollView()
        let firstGap = makeContextGap(
            hiddenLineCount: 4,
            revealedLineNumbers: [7],
            contextRenderID: 1,
            contentPrefix: "old context"
        )
        scrollView.display(
            groups: [makeGroup(includesSecondHunk: true, contextGaps: [firstGap])],
            layout: .unified,
            scrollTarget: nil
        )
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        func labels() -> [String] {
            var values: [String] = []
            for row in 0..<tableView.numberOfRows {
                guard let cell = tableView.view(
                    atColumn: 0,
                    row: row,
                    makeIfNecessary: true
                ) else {
                    continue
                }
                values.append(contentsOf: descendants(of: cell).compactMap {
                    ($0 as? NSTextField)?.stringValue
                })
            }
            return values
        }
        XCTAssertTrue(labels().contains("old context 7"))

        let updatedGap = makeContextGap(
            hiddenLineCount: 4,
            revealedLineNumbers: [7],
            contextRenderID: 2,
            contentPrefix: "new context"
        )
        scrollView.display(
            groups: [makeGroup(includesSecondHunk: true, contextGaps: [updatedGap])],
            layout: .unified,
            scrollTarget: nil
        )

        XCTAssertTrue(labels().contains("new context 7"))
        XCTAssertFalse(labels().contains("old context 7"))
    }

    func testWholeFileContextFillsAroundCompactHunksWithoutMergingThem() throws {
        let group = makeGroup(includesSecondHunk: true)
        let compactDiff = try XCTUnwrap(group.files[0].diff)
        let sourceLines = (3...12).map { lineNumber in
            GitDiffLine(
                id: 100 + lineNumber,
                kind: .context,
                oldLineNumber: lineNumber,
                newLineNumber: lineNumber,
                content: "line \(lineNumber)"
            )
        }
        let sourceDiff = GitFileDiff(
            change: compactDiff.change,
            scope: compactDiff.scope,
            hunks: [
                GitDiffHunk(
                    id: 0,
                    header: "@@ -1,12 +1,12 @@",
                    oldStart: 1,
                    oldCount: 12,
                    newStart: 1,
                    newCount: 12,
                    lines: sourceLines
                )
            ],
            state: .textual
        )

        let gaps = DiffContextGapBuilder.gaps(
            fileID: "sample",
            compactDiff: compactDiff,
            contextSourceDiff: sourceDiff,
            revealedLineCountByGapID: [:],
            revealsWholeFile: true
        )

        XCTAssertEqual(gaps.count, 2)
        XCTAssertEqual(gaps[0].revealedLines.compactMap(\.newLineNumber), Array(3...9))
        XCTAssertEqual(gaps[0].nextHunkAnchorID, "sample:hunk:1")
        XCTAssertEqual(gaps[1].revealedLines.compactMap(\.newLineNumber), [11, 12])
        XCTAssertNil(gaps[1].nextHunkAnchorID)

        let scrollView = makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 500)
        scrollView.display(
            groups: [
                makeGroup(
                    includesSecondHunk: true,
                    showsWholeFile: true,
                    contextGaps: gaps
                )
            ],
            layout: .sideBySide,
            scrollTarget: nil
        )
        scrollView.layoutSubtreeIfNeeded()
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        let hunkCells = (0..<tableView.numberOfRows).compactMap { row in
            let view = tableView.view(atColumn: 0, row: row, makeIfNecessary: true)
            return view?.identifier?.rawValue == "diff-hunk" ? view : nil
        }

        XCTAssertEqual(hunkCells.count, 2)
        XCTAssertTrue(
            hunkCells[0].subviews.compactMap { ($0 as? NSTextField)?.stringValue }
                .contains("Sample.value")
        )
        XCTAssertTrue(
            hunkCells[1].subviews.compactMap { ($0 as? NSTextField)?.stringValue }
                .contains("Sample.flag")
        )
    }

    func testSideBySideHunkHeaderMirrorsTitleAcrossBothPanes() throws {
        let scrollView = makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 160)
        scrollView.display(groups: [makeGroup()], layout: .sideBySide, scrollTarget: nil)
        scrollView.layoutSubtreeIfNeeded()
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        let hunkCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 2, makeIfNecessary: true)
        )
        hunkCell.layoutSubtreeIfNeeded()
        let titleFields = hunkCell.subviews.compactMap { $0 as? NSTextField }.filter {
            $0.identifier?.rawValue == "hunk-title-old"
                || $0.identifier?.rawValue == "hunk-title-new"
        }

        XCTAssertEqual(titleFields.count, 2)
        XCTAssertEqual(titleFields.map(\.stringValue), ["Sample.value", "Sample.value"])
        XCTAssertTrue(titleFields.allSatisfy {
            $0.lineBreakMode == .byTruncatingTail
                && $0.toolTip?.contains("@@") == true
        })
        XCTAssertEqual(titleFields[0].frame.minX, 34, accuracy: 0.5)
        XCTAssertEqual(
            titleFields[1].frame.minX,
            hunkCell.bounds.width / 2 + 34,
            accuracy: 0.5
        )
    }

    func testExpandingContextKeepsNextHunkAtSameViewportPosition() throws {
        let scrollView = makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 120)
        let initialGap = makeContextGap(hiddenLineCount: 7, revealedLineNumbers: [])
        let expandedGap = makeContextGap(hiddenLineCount: 4, revealedLineNumbers: [7, 8, 9])
        scrollView.onExpandContext = { _, _ in
            scrollView.display(
                groups: [
                    self.makeGroup(
                        includesSecondHunk: true,
                        contextGaps: [expandedGap]
                    )
                ],
                layout: .unified,
                scrollTarget: nil
            )
        }
        scrollView.display(
            groups: [makeGroup(includesSecondHunk: true, contextGaps: [initialGap])],
            layout: .unified,
            scrollTarget: nil
        )
        scrollView.layoutSubtreeIfNeeded()
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        let initialHunkRow = 8
        let targetViewportY: CGFloat = 82
        scrollView.contentView.scroll(
            to: NSPoint(
                x: 0,
                y: tableView.rect(ofRow: initialHunkRow).minY - targetViewportY
            )
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let contextEdgeCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 7, makeIfNecessary: true)
        )
        let expandButton = try XCTUnwrap(
            descendants(of: contextEdgeCell).compactMap { $0 as? NSButton }.first {
                $0.identifier?.rawValue == "hunk-context-expand"
            }
        )
        let hunkCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: initialHunkRow, makeIfNecessary: true)
        )
        XCTAssertTrue(
            descendants(of: hunkCell).compactMap { ($0 as? NSTextField)?.stringValue }
                .contains("Sample.flag")
        )

        expandButton.performClick(nil)

        let expandedHunkRow = 11
        XCTAssertEqual(
            tableView.rect(ofRow: expandedHunkRow).minY
                - scrollView.contentView.bounds.minY,
            targetViewportY,
            accuracy: 0.5
        )
    }

    func testShowingWholeFileKeepsVisibleCodeAtSameViewportPosition() throws {
        let scrollView = makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 120)
        let initialGap = makeContextGap(hiddenLineCount: 7, revealedLineNumbers: [])
        let expandedGap = makeContextGap(hiddenLineCount: 4, revealedLineNumbers: [7, 8, 9])
        var anchorViewportY: CGFloat?
        var showsWholeFile = false
        scrollView.onToggleWholeFile = { _ in
            if let currentTableView = scrollView.documentView as? NSTableView {
                anchorViewportY = currentTableView.rect(ofRow: showsWholeFile ? 12 : 9).minY
                    - scrollView.contentView.bounds.minY
            }
            showsWholeFile.toggle()
            scrollView.display(
                groups: [
                    self.makeGroup(
                        includesSecondHunk: true,
                        showsWholeFile: showsWholeFile,
                        contextGaps: [showsWholeFile ? expandedGap : initialGap]
                    )
                ],
                layout: .unified,
                scrollTarget: nil
            )
        }
        scrollView.display(
            groups: [makeGroup(includesSecondHunk: true, contextGaps: [initialGap])],
            layout: .unified,
            scrollTarget: nil
        )
        scrollView.layoutSubtreeIfNeeded()
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        let initialCodeRow = 10
        let targetViewportY: CGFloat = 86
        scrollView.contentView.scroll(
            to: NSPoint(
                x: 0,
                y: tableView.rect(ofRow: initialCodeRow).minY - targetViewportY
            )
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
        scrollView.layoutSubtreeIfNeeded()
        let wholeFileButton = try XCTUnwrap(
            descendants(of: scrollView).compactMap { $0 as? NSButton }.first {
                $0.identifier?.rawValue == "whole-file-toggle" && !$0.isHidden
            }
        )

        wholeFileButton.performClick(nil)

        let expandedCodeRow = 12
        XCTAssertLessThanOrEqual(
            abs(
                tableView.rect(ofRow: expandedCodeRow).minY
                    - scrollView.contentView.bounds.minY
                    - (try XCTUnwrap(anchorViewportY))
            ),
            4
        )

        let hideWholeFileButton = try XCTUnwrap(
            descendants(of: scrollView).compactMap { $0 as? NSButton }.first {
                $0.identifier?.rawValue == "whole-file-toggle" && !$0.isHidden
            }
        )
        hideWholeFileButton.performClick(nil)
        XCTAssertLessThanOrEqual(
            abs(
                tableView.rect(ofRow: 9).minY
                    - scrollView.contentView.bounds.minY
                    - (try XCTUnwrap(anchorViewportY))
            ),
            4
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
            descendants(of: cell).compactMap { $0 as? NSTextField }
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
        var focusedFileID: String?
        scrollView.onFocusFile = { focusedFileID = $0 }
        scrollView.onFileAction = { _, action in fileAction = action }
        scrollView.onSelectionAction = { _, _, action in hunkAction = action }
        scrollView.display(groups: [makeGroup()], layout: .unified, scrollTarget: nil)
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)

        let fileCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 1, makeIfNecessary: true)
        )
        let fileButtons = fileCell.subviews.compactMap { $0 as? NSButton }
        try XCTUnwrap(fileButtons.first { $0.title == "Stage" }).performClick(nil)
        XCTAssertEqual(focusedFileID, "sample")
        XCTAssertEqual(fileAction, .stage)
        fileAction = nil
        let fileDiscard = try XCTUnwrap(fileButtons.first { $0.title == "Discard" })
        fileDiscard.performClick(nil)
        XCTAssertNil(fileAction)
        XCTAssertEqual(fileDiscard.title, "Confirm")
        fileDiscard.performClick(nil)
        XCTAssertEqual(fileAction, .discard)
        XCTAssertEqual(fileDiscard.title, "Discard")

        let hunkCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 2, makeIfNecessary: true)
        )
        let hunkButtons = hunkCell.subviews.compactMap { $0 as? NSButton }
        focusedFileID = nil
        try XCTUnwrap(hunkButtons.first { $0.title == "Stage Hunk" }).performClick(nil)
        XCTAssertEqual(focusedFileID, "sample")
        XCTAssertEqual(hunkAction, .stage)
        hunkAction = nil
        let hunkDiscard = try XCTUnwrap(hunkButtons.first { $0.title == "Discard" })
        hunkDiscard.performClick(nil)
        XCTAssertNil(hunkAction)
        XCTAssertEqual(hunkDiscard.title, "Confirm")
        hunkDiscard.performClick(nil)
        XCTAssertEqual(hunkAction, .discard)
        XCTAssertEqual(hunkDiscard.title, "Discard")
    }

    func testDiffRowsAndContextMenuFocusTheirContainingFile() throws {
        let scrollView = makeScrollView()
        var focusedFileID: String?
        scrollView.onFocusFile = { focusedFileID = $0 }
        scrollView.display(groups: [makeGroup()], layout: .unified, scrollTarget: nil)

        XCTAssertFalse(scrollView.focusFile(atRow: 0))
        XCTAssertNil(focusedFileID)
        XCTAssertTrue(scrollView.focusFile(atRow: 3))
        XCTAssertEqual(focusedFileID, "sample")

        focusedFileID = nil
        _ = scrollView.contextMenu(
            clickedRow: 4,
            selectedRows: IndexSet(integer: 4)
        )
        XCTAssertEqual(focusedFileID, "sample")
    }

    func testDiscardConfirmationsExpireWithoutRunningActions() async throws {
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
        let hunkCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 2, makeIfNecessary: true)
        )
        let fileDiscard = try XCTUnwrap(
            fileCell.subviews.compactMap { $0 as? NSButton }
                .first { $0.title == "Discard" }
        )
        let hunkDiscard = try XCTUnwrap(
            hunkCell.subviews.compactMap { $0 as? NSButton }
                .first { $0.title == "Discard" }
        )

        fileDiscard.performClick(nil)
        hunkDiscard.performClick(nil)
        XCTAssertEqual(fileDiscard.title, "Confirm")
        XCTAssertEqual(hunkDiscard.title, "Confirm")

        try await Task.sleep(for: .milliseconds(3_200))

        XCTAssertEqual(fileDiscard.title, "Discard")
        XCTAssertEqual(hunkDiscard.title, "Discard")
        XCTAssertNil(fileAction)
        XCTAssertNil(hunkAction)
    }

    func testEscapeCancelsDiscardConfirmationsAndReviewHasKeyboardFocusRing() throws {
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
        let hunkCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 2, makeIfNecessary: true)
        )
        let fileDiscard = try XCTUnwrap(
            fileCell.subviews.compactMap { $0 as? NSButton }
                .first { $0.title == "Discard" }
        )
        let hunkDiscard = try XCTUnwrap(
            hunkCell.subviews.compactMap { $0 as? NSButton }
                .first { $0.title == "Discard" }
        )
        fileDiscard.performClick(nil)
        hunkDiscard.performClick(nil)

        tableView.keyDown(with: try makeEscapeEvent())

        XCTAssertEqual(fileDiscard.title, "Discard")
        XCTAssertEqual(hunkDiscard.title, "Discard")
        XCTAssertNil(fileAction)
        XCTAssertNil(hunkAction)
        XCTAssertEqual(tableView.focusRingType, .default)
        XCTAssertEqual(tableView.accessibilityLabel(), "Diff Review")

        fileDiscard.performClick(nil)
        hunkDiscard.performClick(nil)
        tableView.cancelOperation(nil)
        XCTAssertEqual(fileDiscard.title, "Discard")
        XCTAssertEqual(hunkDiscard.title, "Discard")
    }

    func testFileContextMenuExposesWorkingCopyUtilities() throws {
        let scrollView = makeScrollView()
        var receivedAction: DiffStackFileUtilityAction?
        scrollView.onFileUtilityAction = { _, action in
            receivedAction = action
        }
        scrollView.display(groups: [makeGroup()], layout: .unified, scrollTarget: nil)

        let menu = scrollView.contextMenu(
            clickedRow: 1,
            selectedRows: IndexSet(integer: 1)
        )
        let openIndex = menu.indexOfItem(withTitle: "Open File")
        XCTAssertGreaterThanOrEqual(openIndex, 0)
        XCTAssertTrue(menu.item(at: openIndex)?.isEnabled == true)
        XCTAssertTrue(menu.item(withTitle: "Open with Visual Studio Code")?.isEnabled == true)
        XCTAssertNotNil(menu.item(withTitle: "Reveal in Finder"))
        XCTAssertEqual(
            menu.item(withTitle: "Copy Path")?.submenu?.items.map(\.title),
            ["Relative Path", "Absolute Path"]
        )

        menu.performActionForItem(at: openIndex)
        XCTAssertEqual(receivedAction, .openFile)

        scrollView.display(
            groups: [
                makeGroup(
                    canOpenWorkingFile: false,
                    canOpenInVisualStudioCode: false
                )
            ],
            layout: .unified,
            scrollTarget: nil
        )
        let missingMenu = scrollView.contextMenu(
            clickedRow: 1,
            selectedRows: IndexSet(integer: 1)
        )
        XCTAssertTrue(missingMenu.item(withTitle: "Open File")?.isEnabled == false)
        XCTAssertTrue(
            missingMenu.item(withTitle: "Open with Visual Studio Code")?.isEnabled == false
        )
        XCTAssertTrue(missingMenu.item(withTitle: "Reveal in Finder")?.isEnabled == true)
    }

    func testDirtySubmoduleCanDiscardWithoutIneffectiveStageAction() throws {
        let scrollView = makeScrollView()
        scrollView.display(
            groups: [
                makeGroup(
                    canApplyPrimaryAction: false,
                    canDiscard: true
                )
            ],
            layout: .unified,
            scrollTarget: nil
        )
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        let fileCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 1, makeIfNecessary: true)
        )
        let buttons = fileCell.subviews.compactMap { $0 as? NSButton }
        XCTAssertTrue(buttons.first { $0.title == "Stage" }?.isHidden == true)
        XCTAssertTrue(buttons.first { $0.title == "Discard" }?.isHidden == false)

        let menu = scrollView.contextMenu(
            clickedRow: 1,
            selectedRows: IndexSet(integer: 1)
        )
        XCTAssertNil(menu.item(withTitle: "Stage"))
        XCTAssertNotNil(menu.item(withTitle: "Discard File"))
    }

    func testConflictOnlyExposesWholeFileStageAction() throws {
        let scrollView = makeScrollView()
        scrollView.display(
            groups: [
                makeGroup(
                    status: .conflicted,
                    statusLabel: "U",
                    canApplyPrimaryAction: true,
                    canDiscard: false
                )
            ],
            layout: .unified,
            scrollTarget: nil
        )
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        let fileCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 1, makeIfNecessary: true)
        )
        fileCell.layoutSubtreeIfNeeded()
        let fileButtons = descendants(of: fileCell).compactMap { $0 as? NSButton }
        XCTAssertTrue(fileButtons.contains(where: {
            $0.title == "Stage" && !$0.isHidden
        }))
        XCTAssertFalse(fileButtons.contains(where: {
            $0.title == "Discard" && !$0.isHidden
        }))

        let hunkCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 2, makeIfNecessary: true)
        )
        hunkCell.layoutSubtreeIfNeeded()
        let hunkButtons = descendants(of: hunkCell).compactMap { $0 as? NSButton }
        XCTAssertFalse(hunkButtons.contains(where: {
            ["Stage Hunk", "Discard"].contains($0.title) && !$0.isHidden
        }))

        let lineMenu = scrollView.contextMenu(
            clickedRow: 3,
            selectedRows: IndexSet(integer: 3)
        )
        XCTAssertFalse(lineMenu.items.contains(where: {
            $0.title.hasPrefix("Stage Selected")
                || $0.title.hasPrefix("Unstage Selected")
                || $0.title.hasPrefix("Discard Selected")
        }))
    }

    func testGitMutationBusyStateDisablesWritesButKeepsReviewControls() throws {
        let scrollView = makeScrollView()
        scrollView.mutationActionsEnabled = false
        scrollView.display(
            groups: [makeGroup(isMutationEnabled: false)],
            layout: .unified,
            scrollTarget: nil
        )
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        let fileCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 1, makeIfNecessary: true)
        )
        let fileButtons = fileCell.subviews.compactMap { $0 as? NSButton }
        XCTAssertTrue(fileButtons.first { $0.title == "Stage" }?.isEnabled == false)
        XCTAssertTrue(fileButtons.first { $0.title == "Discard" }?.isEnabled == false)
        XCTAssertTrue(
            fileButtons.first { $0.identifier?.rawValue == "review-toggle" }?.isEnabled == true
        )
        XCTAssertTrue(
            fileButtons.first { $0.identifier?.rawValue == "whole-file-toggle" }?.isEnabled == true
        )

        let hunkCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 2, makeIfNecessary: true)
        )
        let hunkButtons = hunkCell.subviews.compactMap { $0 as? NSButton }
        XCTAssertTrue(hunkButtons.first { $0.title == "Stage Hunk" }?.isEnabled == false)
        XCTAssertTrue(hunkButtons.first { $0.title == "Discard" }?.isEnabled == false)

        let fileMenu = scrollView.contextMenu(
            clickedRow: 1,
            selectedRows: IndexSet(integer: 1)
        )
        XCTAssertTrue(fileMenu.item(withTitle: "Stage")?.isEnabled == false)
        XCTAssertTrue(fileMenu.item(withTitle: "Discard File")?.isEnabled == false)
        let lineMenu = scrollView.contextMenu(
            clickedRow: 3,
            selectedRows: IndexSet(integer: 3)
        )
        XCTAssertTrue(lineMenu.item(withTitle: "Stage Selected Line")?.isEnabled == false)
        XCTAssertTrue(lineMenu.item(withTitle: "Discard Selected Line")?.isEnabled == false)
    }

    func testFileHeaderTogglesReviewedForCurrentSnapshot() throws {
        let scrollView = makeScrollView()
        var reviewedFileID: String?
        scrollView.onToggleReviewed = { reviewedFileID = $0 }
        scrollView.display(groups: [makeGroup()], layout: .unified, scrollTarget: nil)
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        var fileCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 1, makeIfNecessary: true)
        )
        var reviewButton = try XCTUnwrap(
            fileCell.subviews.compactMap { $0 as? NSButton }
                .first { $0.identifier?.rawValue == "review-toggle" }
        )
        XCTAssertEqual(reviewButton.toolTip, "Mark as Reviewed")
        reviewButton.performClick(nil)
        XCTAssertEqual(reviewedFileID, "sample")
        XCTAssertTrue(
            scrollView.contextMenu(
                clickedRow: 1,
                selectedRows: IndexSet(integer: 1)
            ).items.contains { $0.title == "Mark as Reviewed" }
        )

        scrollView.display(
            groups: [makeGroup(isReviewed: true)],
            layout: .unified,
            scrollTarget: nil
        )
        fileCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 1, makeIfNecessary: true)
        )
        reviewButton = try XCTUnwrap(
            fileCell.subviews.compactMap { $0 as? NSButton }
                .first { $0.identifier?.rawValue == "review-toggle" }
        )
        XCTAssertEqual(reviewButton.toolTip, "Mark as Unreviewed")
        XCTAssertTrue(
            scrollView.contextMenu(
                clickedRow: 1,
                selectedRows: IndexSet(integer: 1)
            ).items.contains { $0.title == "Mark as Unreviewed" }
        )
    }

    func testFocusAndReviewedUpdatesDoNotRebuildDiffRows() throws {
        let scrollView = makeScrollView()
        scrollView.display(
            groups: [makeGroup()],
            layout: .unified,
            scrollTarget: nil
        )
        XCTAssertEqual(scrollView.rowRebuildCount, 1)

        scrollView.display(
            groups: [makeGroup(isFocused: true, isReviewed: true)],
            layout: .unified,
            scrollTarget: "sample"
        )

        XCTAssertEqual(scrollView.rowRebuildCount, 1)
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        let fileCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 1, makeIfNecessary: true)
        )
        let reviewButton = try XCTUnwrap(
            descendants(of: fileCell).compactMap { $0 as? NSButton }.first {
                $0.accessibilityLabel() == "Mark as Unreviewed"
            }
        )
        XCTAssertFalse(reviewButton.isHidden)
    }

    func testIndexedPresentationUpdateChangesOnlyRequestedFileHeader() throws {
        let scrollView = makeScrollView()
        let first = makeGroup(
            id: "first",
            path: "Sources/First.swift"
        ).files[0]
        let second = makeGroup(
            id: "second",
            path: "Sources/Second.swift"
        ).files[0]
        let initial = DiffStackGroup(
            id: "working",
            title: "Working",
            emptyMessage: "No changes",
            isExpanded: true,
            files: [first, second]
        )
        scrollView.display(groups: [initial], layout: .unified, scrollTarget: nil)

        let updatedSecond = makeGroup(
            id: "second",
            isFocused: true,
            isReviewed: true,
            path: "Sources/Second.swift"
        ).files[0]
        scrollView.display(
            groups: [
                DiffStackGroup(
                    id: initial.id,
                    title: initial.title,
                    emptyMessage: initial.emptyMessage,
                    isExpanded: initial.isExpanded,
                    files: [first, updatedSecond]
                )
            ],
            layout: .unified,
            scrollTarget: nil
        )

        XCTAssertEqual(scrollView.rowRebuildCount, 1)
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        let firstHeader = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 1, makeIfNecessary: true)
        )
        let secondHeaderRow = 1 + 1 + (first.diff?.hunks.reduce(0) {
            $0 + 1 + $1.lines.count
        } ?? 0)
        let secondHeader = try XCTUnwrap(
            tableView.view(atColumn: 0, row: secondHeaderRow, makeIfNecessary: true)
        )
        let firstReview = try XCTUnwrap(
            descendants(of: firstHeader).compactMap { $0 as? NSButton }.first {
                $0.identifier?.rawValue == "review-toggle"
            }
        )
        let secondReview = try XCTUnwrap(
            descendants(of: secondHeader).compactMap { $0 as? NSButton }.first {
                $0.identifier?.rawValue == "review-toggle"
            }
        )
        XCTAssertEqual(firstReview.toolTip, "Mark as Reviewed")
        XCTAssertEqual(secondReview.toolTip, "Mark as Unreviewed")
    }

    func testFileHeaderTogglesWholeFileContext() throws {
        let scrollView = makeScrollView()
        var wholeFileID: String?
        scrollView.onToggleWholeFile = { wholeFileID = $0 }
        scrollView.display(groups: [makeGroup()], layout: .unified, scrollTarget: nil)
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        var fileCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 1, makeIfNecessary: true)
        )
        var wholeFileButton = try XCTUnwrap(
            fileCell.subviews.compactMap { $0 as? NSButton }
                .first { $0.identifier?.rawValue == "whole-file-toggle" }
        )
        XCTAssertEqual(wholeFileButton.toolTip, "Show Whole File")
        XCTAssertNotNil(wholeFileButton.image)
        wholeFileButton.performClick(nil)
        XCTAssertEqual(wholeFileID, "sample")
        XCTAssertTrue(
            scrollView.contextMenu(
                clickedRow: 1,
                selectedRows: IndexSet(integer: 1)
            ).items.contains { $0.title == "Show Whole File" }
        )

        scrollView.display(
            groups: [makeGroup(showsWholeFile: true)],
            layout: .unified,
            scrollTarget: nil
        )
        fileCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 1, makeIfNecessary: true)
        )
        wholeFileButton = try XCTUnwrap(
            fileCell.subviews.compactMap { $0 as? NSButton }
                .first { $0.identifier?.rawValue == "whole-file-toggle" }
        )
        XCTAssertEqual(wholeFileButton.toolTip, "Show Changed Hunks")
        XCTAssertNotNil(wholeFileButton.image)
        XCTAssertTrue(
            scrollView.contextMenu(
                clickedRow: 1,
                selectedRows: IndexSet(integer: 1)
            ).items.contains { $0.title == "Show Changed Hunks" }
        )
    }

    func testHunkHeaderShowsWholeFileToggleOnHover() throws {
        let scrollView = makeScrollView()
        var wholeFileID: String?
        scrollView.onToggleWholeFile = { wholeFileID = $0 }
        scrollView.display(groups: [makeGroup()], layout: .unified, scrollTarget: nil)
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        let hunkCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 2, makeIfNecessary: true)
        )
        let wholeFileButton = try XCTUnwrap(
            descendants(of: hunkCell).compactMap { $0 as? NSButton }.first {
                $0.identifier?.rawValue == "hunk-whole-file-toggle"
            }
        )

        XCTAssertTrue(wholeFileButton.isHidden)
        hunkCell.mouseEntered(with: try makeMouseMoveEvent())
        XCTAssertFalse(wholeFileButton.isHidden)
        wholeFileButton.performClick(nil)
        XCTAssertEqual(wholeFileID, "sample")
    }

    func testChangedLineContextMenuExposesLineActions() throws {
        let scrollView = makeScrollView()
        var discardedLineIDs: Set<GitDiffLine.ID> = []
        scrollView.onSelectionAction = { _, lineIDs, action in
            if action == .discard {
                discardedLineIDs = lineIDs
            }
        }
        scrollView.display(groups: [makeGroup()], layout: .unified, scrollTarget: nil)

        let menu = scrollView.contextMenu(
            clickedRow: 4,
            selectedRows: IndexSet(integersIn: 3...4)
        )
        let titles = menu.items.map(\.title)

        XCTAssertTrue(titles.contains("Stage Selected Lines"))
        let discardItem = try XCTUnwrap(
            menu.items.first { $0.title == "Discard Selected Lines" }
        )
        XCTAssertEqual(
            discardItem.submenu?.items.first?.title,
            "Confirm Discard Selected Lines — Save Backup in Trash"
        )
        try XCTUnwrap(discardItem.submenu).performActionForItem(at: 0)
        XCTAssertEqual(discardedLineIDs, [0, 1])
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

        let outputDirectory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(".build/verification", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        let output = outputDirectory.appendingPathComponent(
            "AgentGitDiffStack-side-by-side.png"
        )
        try png.write(to: output)
        print("AgentGit offscreen snapshot: \(output.path)")
    }

    func testRendersDarkSideBySideSnapshotOffscreen() throws {
        let scrollView = makeScrollView()
        scrollView.appearance = NSAppearance(named: .darkAqua)
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

        let outputDirectory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(".build/verification", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        let output = outputDirectory.appendingPathComponent(
            "AgentGitDiffStack-side-by-side-dark.png"
        )
        try png.write(to: output)
        print("AgentGit dark offscreen snapshot: \(output.path)")
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

    private func makeEscapeEvent() throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\u{1B}",
                charactersIgnoringModifiers: "\u{1B}",
                isARepeat: false,
                keyCode: 53
            )
        )
    }

    private func makeMouseMoveEvent() throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .mouseMoved,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 0,
                pressure: 0
            )
        )
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private func codeRegion(
        containing text: String,
        in tableView: NSTableView
    ) throws -> (cell: NSView, content: NSView, tablePoint: NSPoint) {
        for row in 0..<tableView.numberOfRows {
            guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: true) else {
                continue
            }
            cell.layoutSubtreeIfNeeded()
            guard let content = descendants(of: cell).first(where: { view in
                guard view.identifier?.rawValue == "diff-new-code-content",
                      let field = view as? NSTextField else {
                    return false
                }
                return field.stringValue == text
            }), let clip = descendants(of: cell).first(where: {
                $0.identifier?.rawValue == "diff-new-code-clip"
            }) else {
                continue
            }
            return (
                cell: cell,
                content: content,
                tablePoint: tableView.convert(
                    NSPoint(x: clip.frame.midX, y: clip.frame.midY),
                    from: cell
                )
            )
        }
        XCTFail("Unable to find code region containing expected text")
        throw TestSupportError.codeRegionMissing
    }

    private func makeGroup(
        id: String = "sample",
        includesSecondHunk: Bool = false,
        isFocused: Bool = false,
        isReviewed: Bool = false,
        showsWholeFile: Bool = false,
        contextGaps: [DiffStackContextGap] = [],
        path: String = "Sources/Sample.swift",
        originalPath: String? = nil,
        status: DiffStackStatus = .modified,
        statusLabel: String = "M",
        additionContent: String = "let newValue = 2",
        secondAdditionContent: String = "let newFlag = true",
        canOpenWorkingFile: Bool = true,
        canOpenInVisualStudioCode: Bool = true,
        canApplyPrimaryAction: Bool = true,
        canDiscard: Bool = true,
        isMutationEnabled: Bool = true
    ) -> DiffStackGroup {
        let change = GitFileChange(
            path: path,
            originalPath: originalPath,
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
                content: additionContent
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
                sectionHeading: "Sample.value",
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
                        sectionHeading: "Sample.flag",
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
                            content: secondAdditionContent
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
                    id: id,
                    path: change.path,
                    originalPath: change.originalPath,
                    status: status,
                    statusLabel: statusLabel,
                    isExpanded: true,
                    isFocused: isFocused,
                    isReviewed: isReviewed,
                    showsWholeFile: showsWholeFile,
                    isLoadingWholeFile: false,
                    canToggleWholeFile: true,
                    canOpenWorkingFile: canOpenWorkingFile,
                    canOpenInVisualStudioCode: canOpenInVisualStudioCode,
                    canApplyPrimaryAction: canApplyPrimaryAction,
                    canDiscard: canDiscard,
                    isMutationEnabled: isMutationEnabled,
                    contextGaps: contextGaps,
                    mutationMode: .working,
                    diff: diff,
                    imageDiff: nil
                )
            ]
        )
    }

    private func makeImageGroup(
        oldImageData: Data,
        newImageData: Data
    ) -> DiffStackGroup {
        let change = GitFileChange(
            path: "Assets/icon.png",
            originalPath: nil,
            indexStatus: ".",
            worktreeStatus: "M",
            kind: .ordinary
        )
        let diff = GitFileDiff(
            change: change,
            scope: .working,
            hunks: [],
            state: .binary
        )
        return DiffStackGroup(
            id: "working",
            title: "Working",
            emptyMessage: "No changes",
            isExpanded: true,
            files: [
                DiffStackFile(
                    id: "image",
                    path: change.path,
                    originalPath: change.originalPath,
                    status: .modified,
                    statusLabel: "M",
                    isExpanded: true,
                    isFocused: false,
                    isReviewed: false,
                    showsWholeFile: false,
                    isLoadingWholeFile: false,
                    canToggleWholeFile: false,
                    canOpenWorkingFile: true,
                    canOpenInVisualStudioCode: true,
                    canApplyPrimaryAction: true,
                    canDiscard: true,
                    isMutationEnabled: true,
                    contextGaps: [],
                    mutationMode: .working,
                    diff: diff,
                    imageDiff: GitImageDiff(
                        oldImage: GitImageBlob(path: "Assets/icon.png", contents: oldImageData),
                        newImage: GitImageBlob(path: "Assets/icon.png", contents: newImageData)
                    )
                )
            ]
        )
    }

    private func makeMetadataGroup(summary: String) -> DiffStackGroup {
        let change = GitFileChange(
            path: "Scripts/deploy.sh",
            originalPath: nil,
            indexStatus: ".",
            worktreeStatus: "M",
            kind: .ordinary
        )
        let diff = GitFileDiff(
            change: change,
            scope: .working,
            hunks: [],
            state: .metadata(summary)
        )
        return DiffStackGroup(
            id: "working",
            title: "Working",
            emptyMessage: "No changes",
            isExpanded: true,
            files: [
                DiffStackFile(
                    id: "metadata",
                    path: change.path,
                    originalPath: nil,
                    status: .modified,
                    statusLabel: "M",
                    isExpanded: true,
                    isFocused: false,
                    isReviewed: false,
                    showsWholeFile: false,
                    isLoadingWholeFile: false,
                    canToggleWholeFile: false,
                    canOpenWorkingFile: true,
                    canOpenInVisualStudioCode: true,
                    canApplyPrimaryAction: true,
                    canDiscard: true,
                    isMutationEnabled: true,
                    contextGaps: [],
                    mutationMode: .working,
                    diff: diff,
                    imageDiff: nil
                )
            ]
        )
    }

    private func makeContextGap(
        hiddenLineCount: Int,
        revealedLineNumbers: [Int],
        contextRenderID: UInt64? = 1,
        contentPrefix: String = "line"
    ) -> DiffStackContextGap {
        DiffStackContextGap(
            id: "sample:context:0->1",
            hiddenLineCount: hiddenLineCount,
            revealedLines: revealedLineNumbers.map { lineNumber in
                GitDiffLine(
                    id: 100 + lineNumber,
                    kind: .context,
                    oldLineNumber: lineNumber + 1,
                    newLineNumber: lineNumber,
                    content: "\(contentPrefix) \(lineNumber)"
                )
            },
            nextHunkAnchorID: "sample:hunk:1",
            contextRenderID: contextRenderID
        )
    }
}

private enum TestSupportError: Error {
    case codeRegionMissing
}
