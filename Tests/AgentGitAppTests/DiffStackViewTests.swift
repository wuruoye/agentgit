import AgentGitCore
import AppKit
import XCTest
@testable import AgentGitApp

@MainActor
final class DiffStackViewTests: XCTestCase {
    func testCodeHitTestingReachesSelectableTextView() throws {
        let scrollView = makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 300)
        scrollView.display(
            groups: [makeGroup()],
            layout: .sideBySide,
            scrollTarget: nil
        )
        scrollView.layoutSubtreeIfNeeded()
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        let cell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 3, makeIfNecessary: true)
        )
        cell.layoutSubtreeIfNeeded()
        let textView = try XCTUnwrap(
            descendants(of: cell).compactMap { $0 as? NSTextView }.first {
                $0.identifier?.rawValue == "diff-old-code-content"
            }
        )
        let point = tableView.convert(
            NSPoint(x: textView.bounds.midX, y: textView.bounds.midY),
            from: textView
        )

        XCTAssertTrue(tableView.hitTest(point) === textView)
        XCTAssertTrue(textView.acceptsFirstResponder)
    }

    func testDraggingAcrossCodeRowsSelectsTextFromEveryDraggedRow() throws {
        let scrollView = makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 300)
        scrollView.display(
            groups: [makeGroup()],
            layout: .sideBySide,
            scrollTarget: nil
        )
        let window = NSWindow(
            contentRect: scrollView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        scrollView.layoutSubtreeIfNeeded()
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        let firstTextView = try oldCodeTextView(in: tableView, row: 3)
        let secondTextView = try oldCodeTextView(in: tableView, row: 4)
        let start = firstTextView.convert(
            NSPoint(x: 8, y: firstTextView.bounds.midY),
            to: nil
        )
        let end = secondTextView.convert(
            NSPoint(x: 60, y: secondTextView.bounds.midY),
            to: nil
        )
        let windowNumber = window.windowNumber
        let down = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: start,
                modifierFlags: [],
                timestamp: 1,
                windowNumber: windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            )
        )
        let dragged = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDragged,
                location: end,
                modifierFlags: [],
                timestamp: 2,
                windowNumber: windowNumber,
                context: nil,
                eventNumber: 2,
                clickCount: 1,
                pressure: 1
            )
        )
        let up = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: end,
                modifierFlags: [],
                timestamp: 3,
                windowNumber: windowNumber,
                context: nil,
                eventNumber: 3,
                clickCount: 1,
                pressure: 0
            )
        )
        NSApp.postEvent(dragged, atStart: false)
        NSApp.postEvent(up, atStart: false)

        // AppKit 把代码上的点击直接派给这个文本视图，不经过表格。
        firstTextView.mouseDown(with: down)

        let selected = scrollView.codeSelectionText()
        let selectedLines = selected.components(separatedBy: "\n")
        XCTAssertEqual(selectedLines.count, 2, selected)
        XCTAssertTrue(
            "let oldValue = 1".hasSuffix(try XCTUnwrap(selectedLines.first)),
            selected
        )
        XCTAssertTrue(
            "return oldValue".hasPrefix(try XCTUnwrap(selectedLines.last)),
            selected
        )
        XCTAssertFalse(try XCTUnwrap(selectedLines.first).isEmpty, selected)
        XCTAssertFalse(try XCTUnwrap(selectedLines.last).isEmpty, selected)
        XCTAssertTrue(tableView.selectedRowIndexes.isEmpty)
    }

    func testDraggingAcrossUnifiedCodeRowsSelectsTextFromEveryDraggedRow() throws {
        let scrollView = makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 300)
        scrollView.display(
            groups: [makeGroup()],
            layout: .unified,
            scrollTarget: nil
        )
        let window = NSWindow(
            contentRect: scrollView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        scrollView.layoutSubtreeIfNeeded()
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        let firstTextView = try codeTextView(
            in: tableView,
            row: 3,
            identifier: "diff-unified-code-content"
        )
        let secondTextView = try codeTextView(
            in: tableView,
            row: 4,
            identifier: "diff-unified-code-content"
        )
        let bandBeforeDrag = topEdgeOpaquePixelCount(of: firstTextView)
        let start = firstTextView.convert(
            NSPoint(x: 8, y: firstTextView.bounds.midY),
            to: nil
        )
        let end = secondTextView.convert(
            NSPoint(x: 60, y: secondTextView.bounds.midY),
            to: nil
        )
        let windowNumber = window.windowNumber
        let down = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: start,
                modifierFlags: [],
                timestamp: 1,
                windowNumber: windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            )
        )
        let dragged = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDragged,
                location: end,
                modifierFlags: [],
                timestamp: 2,
                windowNumber: windowNumber,
                context: nil,
                eventNumber: 2,
                clickCount: 1,
                pressure: 1
            )
        )
        let up = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: end,
                modifierFlags: [],
                timestamp: 3,
                windowNumber: windowNumber,
                context: nil,
                eventNumber: 3,
                clickCount: 1,
                pressure: 0
            )
        )
        NSApp.postEvent(dragged, atStart: false)
        NSApp.postEvent(up, atStart: false)

        // AppKit 把代码上的点击直接派给这个文本视图，不经过表格。
        firstTextView.mouseDown(with: down)

        let selected = scrollView.codeSelectionText()
        XCTAssertEqual(selected.components(separatedBy: "\n").count, 2, selected)
        // 选中了但没画出来等于用户看不见选区：字形碰不到行顶那一像素行，
        // 那里变成不透明只可能是选区底色铺满了整行高。
        XCTAssertEqual(bandBeforeDrag, 0)
        XCTAssertGreaterThan(topEdgeOpaquePixelCount(of: firstTextView), 100)
    }

    private func topEdgeOpaquePixelCount(of view: NSView) -> Int {
        guard let representation = view.bitmapImageRepForCachingDisplay(
            in: view.bounds
        ) else {
            return 0
        }
        view.cacheDisplay(in: view.bounds, to: representation)
        return (0..<representation.pixelsWide).count { x in
            (representation.colorAt(x: x, y: 0)?.alphaComponent ?? 0) > 0.05
        }
    }

    private func oldCodeTextView(
        in tableView: NSTableView,
        row: Int
    ) throws -> NSTextView {
        try codeTextView(
            in: tableView,
            row: row,
            identifier: "diff-old-code-content"
        )
    }

    private func codeTextView(
        in tableView: NSTableView,
        row: Int,
        identifier: String
    ) throws -> NSTextView {
        let cell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: row, makeIfNecessary: true)
        )
        cell.layoutSubtreeIfNeeded()
        return try XCTUnwrap(
            descendants(of: cell).compactMap { $0 as? NSTextView }.first {
                $0.identifier?.rawValue == identifier
            }
        )
    }

    func testRedisplayWithFewerRowsDoesNotCrash() throws {
        // 重画时行数变少：rebuildRows 已经把 rows 换短，reloadData 还没跑，这时如果
        // 通知 AppKit 行高变化，它会按旧行数回头要视图，直接下标越界闪退。
        let scrollView = makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 400)
        let longSummary = DiffStackSummary(
            commit: GitCommit(
                oid: String(repeating: "a", count: 40),
                shortOID: "aaaaaaa",
                authorName: "Review Author",
                authoredAt: Date(timeIntervalSince1970: 100),
                parentOIDs: [String(repeating: "b", count: 40)],
                refNames: ["refs/heads/main"],
                subject: "Shrink the row count on redisplay"
            ),
            metadata: GitCommitMetadata(
                treeOID: String(repeating: "c", count: 40),
                authorEmail: "review@example.com"
            ),
            message: String(
                repeating: "A long commit body line that forces a tall summary row.\n",
                count: 12
            ),
            fileCount: 1,
            addedLineCount: 2,
            deletedLineCount: 2,
            isFileListExpanded: true
        )
        scrollView.display(
            summary: longSummary,
            groups: [makeGroup(includesSecondHunk: true)],
            layout: .unified,
            scrollTarget: nil
        )
        scrollView.layoutSubtreeIfNeeded()
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        let initialRowCount = tableView.numberOfRows
        XCTAssertGreaterThan(initialRowCount, 4)

        scrollView.display(
            summary: DiffStackSummary(isFileListExpanded: false),
            groups: [makeGroup(isFileExpanded: false)],
            layout: .unified,
            scrollTarget: nil
        )
        scrollView.layoutSubtreeIfNeeded()

        XCTAssertLessThan(tableView.numberOfRows, initialRowCount)
        for row in 0..<tableView.numberOfRows {
            XCTAssertNotNil(tableView.view(atColumn: 0, row: row, makeIfNecessary: true))
        }
    }

    func testSummaryAndFilesShareOneScrollableTable() throws {
        let scrollView = makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 180)
        var requestedExpansion: Bool?
        scrollView.onSetAllFilesExpanded = { requestedExpansion = $0 }
        let commit = GitCommit(
            oid: String(repeating: "a", count: 40),
            shortOID: "aaaaaaa",
            authorName: "Review Author",
            authoredAt: Date(timeIntervalSince1970: 100),
            parentOIDs: [String(repeating: "b", count: 40)],
            refNames: ["refs/heads/main"],
            subject: "Keep summary in the review scroll"
        )
        let summary = DiffStackSummary(
            commit: commit,
            metadata: GitCommitMetadata(
                treeOID: String(repeating: "c", count: 40),
                authorEmail: "review@example.com"
            ),
            message: "Keep summary in the review scroll\n\nDetailed body.",
            fileCount: 1,
            addedLineCount: 2,
            deletedLineCount: 2,
            isFileListExpanded: false
        )
        scrollView.display(
            summary: summary,
            groups: [makeGroup(includesSecondHunk: true)],
            layout: .sideBySide,
            scrollTarget: nil
        )
        scrollView.layoutSubtreeIfNeeded()
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        let summaryCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 0, makeIfNecessary: true)
        )
        XCTAssertEqual(summaryCell.identifier?.rawValue, "diff-summary")
        XCTAssertGreaterThan(tableView.rect(ofRow: 0).height, 120)
        XCTAssertGreaterThan(
            tableView.rect(ofRow: 1).minY,
            tableView.rect(ofRow: 0).maxY - 1
        )
        XCTAssertNil(requestedExpansion)

        scrollView.contentView.scroll(
            to: NSPoint(x: 0, y: tableView.rect(ofRow: 0).maxY)
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
        XCTAssertLessThanOrEqual(
            tableView.rect(ofRow: 0).maxY - scrollView.contentView.bounds.minY,
            0.5
        )
    }

    func testFileHeaderButtonsReceiveClicksBeforeRowDisclosure() {
        XCTAssertFalse(shouldToggleDiffRow(for: NSButton()))
        let selectableText = NSTextField()
        selectableText.isSelectable = true
        XCTAssertFalse(shouldToggleDiffRow(for: selectableText))
        let staticText = NSTextField()
        staticText.isSelectable = false
        XCTAssertTrue(shouldToggleDiffRow(for: staticText))
        let selectableTextView = NSTextView()
        selectableTextView.isSelectable = true
        XCTAssertFalse(shouldToggleDiffRow(for: selectableTextView))
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

        let firstPairCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 3, makeIfNecessary: true)
        )
        firstPairCell.frame = NSRect(x: 0, y: 0, width: 1_000, height: 20)
        firstPairCell.layoutSubtreeIfNeeded()
        let firstPairText = descendants(of: firstPairCell).compactMap { view -> String? in
            guard let textView = view as? NSTextView,
                  view.identifier?.rawValue == "diff-old-code-content"
                    || view.identifier?.rawValue == "diff-new-code-content" else {
                return nil
            }
            return textView.string
        }
        XCTAssertEqual(firstPairText, ["let oldValue = 1", "let newValue = 2"])
        let oldCodeClip = try XCTUnwrap(
            descendants(of: firstPairCell).first {
                $0.identifier?.rawValue == "diff-old-code-clip"
            }
        )
        let oldCodeContent = try XCTUnwrap(
            descendants(of: firstPairCell).first {
                $0.identifier?.rawValue == "diff-old-code-content"
            }
        )
        XCTAssertGreaterThan(oldCodeClip.frame.width, 0)
        XCTAssertGreaterThan(oldCodeContent.frame.width, 0)
        XCTAssertTrue(oldCodeClip.bounds.intersects(oldCodeContent.frame))
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
            labels.contains("Legacy/OldName.swift  →  Sources/NewName.swift")
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
                isExpanded: true,
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

    func testFolderRowsKeepFilesCollapsedUntilFolderExpansion() throws {
        let scrollView = makeScrollView()
        let base = makeGroup()
        let folderID = "navigator-folder:working:Sources"
        let collapsed = DiffStackGroup(
            id: base.id,
            title: base.title,
            emptyMessage: base.emptyMessage,
            isExpanded: true,
            files: base.files,
            folders: [
                DiffStackFolder(
                    id: folderID,
                    title: "Sources",
                    isExpanded: false,
                    fileIDs: base.files.map(\.id)
                )
            ]
        )
        scrollView.display(groups: [collapsed], layout: .sideBySide, scrollTarget: nil)
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        XCTAssertEqual(tableView.numberOfRows, 2)
        let folderCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 1, makeIfNecessary: true)
        )
        XCTAssertTrue(
            descendants(of: folderCell).compactMap {
                ($0 as? NSTextField)?.stringValue
            }.contains("Sources")
        )

        let expanded = DiffStackGroup(
            id: base.id,
            title: base.title,
            emptyMessage: base.emptyMessage,
            isExpanded: true,
            files: base.files,
            folders: [
                DiffStackFolder(
                    id: folderID,
                    title: "Sources",
                    isExpanded: true,
                    fileIDs: base.files.map(\.id)
                )
            ]
        )
        scrollView.display(groups: [expanded], layout: .sideBySide, scrollTarget: nil)
        XCTAssertEqual(tableView.numberOfRows, 7)
        let fileCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 2, makeIfNecessary: true)
        )
        XCTAssertTrue(
            descendants(of: fileCell).compactMap {
                ($0 as? NSTextField)?.stringValue
            }.contains(where: { $0.contains("Sample.swift") })
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
            XCTAssertEqual(tableView.effectiveStyle, .plain)
            XCTAssertEqual(
                tableView.frame.width,
                scrollView.contentView.bounds.width,
                accuracy: 0.5
            )
            XCTAssertEqual(
                scrollView.contentView.bounds.width - column.width,
                0,
                accuracy: 0.5
            )
            XCTAssertFalse(scrollView.hasHorizontalScroller)
            XCTAssertTrue(scrollView.usesPredominantAxisScrolling)
            XCTAssertEqual(scrollView.horizontalScrollElasticity, .none)

            let firstCell = try XCTUnwrap(
                tableView.view(atColumn: 0, row: 0, makeIfNecessary: true)
            )
            XCTAssertEqual(firstCell.frame.minX, 0, accuracy: 0.5)
            XCTAssertEqual(
                tableView.frame.width - firstCell.frame.maxX,
                0,
                accuracy: 0.5
            )
            XCTAssertEqual(tableView.rect(ofRow: 0).minY, 0, accuracy: 0.5)

            scrollView.frame = NSRect(x: 0, y: 0, width: 760, height: 600)
            scrollView.layoutSubtreeIfNeeded()
            XCTAssertEqual(
                tableView.frame.width,
                scrollView.contentView.bounds.width,
                accuracy: 0.5
            )
            XCTAssertEqual(
                scrollView.contentView.bounds.width - column.width,
                0,
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
                        mutationSnapshotID: DiffReviewSnapshotID(diff: diff),
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

        XCTAssertTrue(stage.isHidden)
        XCTAssertTrue(discard.isHidden)
        fileCell.mouseEntered(with: try makeMouseMoveEvent())
        fileCell.layoutSubtreeIfNeeded()
        XCTAssertFalse(stage.isHidden)
        XCTAssertFalse(discard.isHidden)
        XCTAssertGreaterThanOrEqual(stage.frame.minX, fileCell.bounds.minX)
        XCTAssertLessThanOrEqual(stage.frame.maxX, fileCell.bounds.maxX)
        XCTAssertGreaterThanOrEqual(discard.frame.minX, fileCell.bounds.minX)
        XCTAssertLessThanOrEqual(discard.frame.maxX, fileCell.bounds.maxX)
        XCTAssertGreaterThanOrEqual(menu.frame.minX, fileCell.bounds.minX)
        XCTAssertLessThanOrEqual(menu.frame.maxX, fileCell.bounds.maxX)
        XCTAssertGreaterThanOrEqual(menu.frame.width, 24)
        XCTAssertEqual(menu.toolTip, "File Actions")
        XCTAssertEqual(menu.accessibilityLabel(), "File Actions")
        XCTAssertEqual(title.lineBreakMode, .byTruncatingMiddle)
    }

    func testDeletedFileHeaderUsesSublimeStatusAndStatisticsStructure() throws {
        let scrollView = makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 900, height: 160)
        scrollView.display(
            groups: [
                makeGroup(
                    isFileExpanded: false,
                    status: .deleted,
                    statusLabel: "D",
                    canApplyPrimaryAction: false,
                    canDiscard: false,
                    mutationMode: nil
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
        let statusLabel = try XCTUnwrap(
            descendants(of: fileCell).compactMap { $0 as? NSTextField }.first {
                $0.identifier?.rawValue == "file-status-label"
            }
        )
        let statistics = try XCTUnwrap(
            descendants(of: fileCell).first {
                $0.identifier?.rawValue == "file-diff-stats"
            }
        )

        XCTAssertFalse(statusLabel.isHidden)
        XCTAssertEqual(statusLabel.stringValue, "D")
        XCTAssertEqual(statusLabel.accessibilityLabel(), "Deleted File")
        XCTAssertEqual(
            statistics.accessibilityLabel(),
            "2 deletions, 1 addition"
        )
    }

    func testRendersSublimeAlignedCollapsedFileListOffscreen() throws {
        let files = try [
            makeGroup(
                id: "readme",
                isFileExpanded: false,
                isFocused: true,
                path: "agents/README.md",
                canApplyPrimaryAction: false,
                canDiscard: false,
                mutationMode: nil
            ),
            makeGroup(
                id: "deleted",
                isFileExpanded: false,
                path: ".agents/skills/concurrency/SKILL.md",
                status: .deleted,
                statusLabel: "D",
                canApplyPrimaryAction: false,
                canDiscard: false,
                mutationMode: nil
            ),
            makeGroup(
                id: "pipeline",
                isFileExpanded: false,
                path: ".agents/skills/pipeline-change/SKILL.md",
                canApplyPrimaryAction: false,
                canDiscard: false,
                mutationMode: nil
            ),
            makeGroup(
                id: "deploy",
                isFileExpanded: false,
                path: "devops/release/deploy.sh",
                canApplyPrimaryAction: false,
                canDiscard: false,
                mutationMode: nil
            )
        ].map { group in
            try XCTUnwrap(group.files.first)
        }
        let scrollView = makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 1_200, height: 180)
        let window = NSWindow(
            contentRect: scrollView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        scrollView.display(
            summary: DiffStackSummary(isFileListExpanded: false),
            groups: [
                DiffStackGroup(
                    id: "context",
                    title: nil,
                    emptyMessage: "No file changes",
                    isExpanded: true,
                    files: files
                )
            ],
            layout: .sideBySide,
            scrollTarget: nil
        )
        scrollView.layoutSubtreeIfNeeded()
        scrollView.displayIfNeeded()

        let bitmap = try XCTUnwrap(
            scrollView.bitmapImageRepForCachingDisplay(in: scrollView.bounds)
        )
        scrollView.cacheDisplay(in: scrollView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 10_000)
        XCTAssertGreaterThan(sampledColorSignatures(in: bitmap).count, 8)
        let output = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        .appendingPathComponent(".build/verification", isDirectory: true)
        .appendingPathComponent("AgentGitChanged-files-sublime.png")
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try png.write(to: output)
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

    func testVisibleSideBySideRowsKeepBothCodePanesVisibleAndIndependentlyClipped() throws {
        let scrollView = makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 1_200, height: 420)
        scrollView.display(
            groups: [makeGroup(canToggleWholeFile: true)],
            layout: .sideBySide,
            scrollTarget: nil
        )
        scrollView.layoutSubtreeIfNeeded()
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        tableView.layoutSubtreeIfNeeded()
        let pairCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 3, makeIfNecessary: true)
        )
        pairCell.layoutSubtreeIfNeeded()

        let oldCodeClip = try XCTUnwrap(
            descendants(of: pairCell).first {
                $0.identifier?.rawValue == "diff-old-code-clip"
            }
        )
        let newCodeClip = try XCTUnwrap(
            descendants(of: pairCell).first {
                $0.identifier?.rawValue == "diff-new-code-clip"
            }
        )
        let oldCodeContent = try XCTUnwrap(
            descendants(of: pairCell).first {
                $0.identifier?.rawValue == "diff-old-code-content"
            } as? NSTextView
        )
        let newCodeContent = try XCTUnwrap(
            descendants(of: pairCell).first {
                $0.identifier?.rawValue == "diff-new-code-content"
            } as? NSTextView
        )
        XCTAssertGreaterThan(oldCodeClip.frame.width, 0)
        XCTAssertGreaterThan(newCodeClip.frame.width, 0)
        XCTAssertEqual(oldCodeClip.frame.width, newCodeClip.frame.width, accuracy: 0.5)
        XCTAssertEqual(oldCodeContent.frame, newCodeContent.frame)
        XCTAssertEqual(oldCodeContent.alphaValue, 1)
        XCTAssertFalse(oldCodeContent.isHidden)
        XCTAssertFalse(oldCodeClip.isHidden)

        let bitmap = try XCTUnwrap(
            pairCell.bitmapImageRepForCachingDisplay(in: pairCell.bounds)
        )
        pairCell.cacheDisplay(in: pairCell.bounds, to: bitmap)
        let scaleX = CGFloat(bitmap.pixelsWide) / pairCell.bounds.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / pairCell.bounds.height
        let oldBackground = try XCTUnwrap(
            bitmap.colorAt(
                x: Int(500 * scaleX),
                y: Int(10 * scaleY)
            )?.usingColorSpace(.sRGB)
        )
        let newBackground = try XCTUnwrap(
            bitmap.colorAt(
                x: Int(1_100 * scaleX),
                y: Int(10 * scaleY)
            )?.usingColorSpace(.sRGB)
        )
        XCTAssertGreaterThan(oldBackground.redComponent, oldBackground.greenComponent)
        XCTAssertGreaterThan(newBackground.greenComponent, newBackground.redComponent)
    }

    func testNativeDiffPaletteKeepsAdditionAndDeletionVisuallyDistinct() throws {
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        var addition = NSColor.clear
        var deletion = NSColor.clear
        appearance.performAsCurrentDrawingAppearance {
            addition = AgentGitPalette.additionBackground.usingColorSpace(.sRGB) ?? .clear
            deletion = AgentGitPalette.deletionBackground.usingColorSpace(.sRGB) ?? .clear
        }

        XCTAssertGreaterThan(addition.greenComponent, addition.redComponent)
        XCTAssertGreaterThan(deletion.redComponent, deletion.greenComponent)
        XCTAssertNotEqual(addition, deletion)
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

    func testWideningViewportClampsHorizontalOffsetBackIntoVisibleCodeArea() throws {
        let scrollView = makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 520, height: 600)
        let longLine = "let generatedSymbol = "
            + String(repeating: "namespace_component_", count: 24)
        scrollView.display(
            groups: [makeGroup(additionContent: longLine)],
            layout: .sideBySide,
            scrollTarget: nil
        )
        scrollView.layoutSubtreeIfNeeded()
        var tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        let narrow = try codeRegion(containing: longLine, in: tableView)

        XCTAssertTrue(
            scrollView.scrollCodeHorizontally(by: -10_000, atTablePoint: narrow.tablePoint)
        )
        narrow.cell.layoutSubtreeIfNeeded()
        XCTAssertLessThan(narrow.content.frame.minX, 0)

        scrollView.frame = NSRect(x: 0, y: 0, width: 10_000, height: 600)
        scrollView.layoutSubtreeIfNeeded()
        tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        let wide = try codeRegion(containing: longLine, in: tableView)
        wide.cell.layoutSubtreeIfNeeded()

        XCTAssertEqual(wide.content.frame.minX, 0, accuracy: 0.5)
        XCTAssertEqual(scrollView.contentView.bounds.minX, 0, accuracy: 0.5)
    }

    func testContextExpansionPreservesEachHunksHorizontalOffset() throws {
        let scrollView = makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 760, height: 600)
        let firstLine = "let firstGeneratedSymbol = "
            + String(repeating: "first_namespace_component_", count: 32)
        let secondLine = "let secondGeneratedSymbol = "
            + String(repeating: "second_namespace_component_", count: 32)
        let initialGap = makeContextGap(hiddenLineCount: 7, revealedLineNumbers: [])
        let expandedGap = makeContextGap(hiddenLineCount: 4, revealedLineNumbers: [7, 8, 9])
        scrollView.onExpandContext = { _, _ in
            scrollView.display(
                groups: [
                    self.makeGroup(
                        includesSecondHunk: true,
                        contextGaps: [expandedGap],
                        additionContent: firstLine,
                        secondAdditionContent: secondLine
                    )
                ],
                layout: .sideBySide,
                scrollTarget: nil
            )
        }
        scrollView.display(
            groups: [
                makeGroup(
                    includesSecondHunk: true,
                    contextGaps: [initialGap],
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
        XCTAssertTrue(
            scrollView.scrollCodeHorizontally(by: -180, atTablePoint: first.tablePoint)
        )
        XCTAssertTrue(
            scrollView.scrollCodeHorizontally(by: -90, atTablePoint: second.tablePoint)
        )
        first.cell.layoutSubtreeIfNeeded()
        second.cell.layoutSubtreeIfNeeded()
        let firstOffset = first.content.frame.minX
        let secondOffset = second.content.frame.minX
        let expandButton = try XCTUnwrap(
            descendants(of: scrollView).compactMap { $0 as? NSButton }.first {
                $0.identifier?.rawValue == "hunk-context-expand" && !$0.isHidden
            }
        )

        expandButton.performClick(nil)
        scrollView.layoutSubtreeIfNeeded()
        let expandedFirst = try codeRegion(containing: firstLine, in: tableView)
        let expandedSecond = try codeRegion(containing: secondLine, in: tableView)
        expandedFirst.cell.layoutSubtreeIfNeeded()
        expandedSecond.cell.layoutSubtreeIfNeeded()

        XCTAssertEqual(expandedFirst.content.frame.minX, firstOffset, accuracy: 0.5)
        XCTAssertEqual(expandedSecond.content.frame.minX, secondOffset, accuracy: 0.5)
    }

    func testContextExpansionRebuildsOnlyWhenRevealedRowsChange() throws {
        let scrollView = makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 300)
        let initialGap = makeContextGap(
            hiddenLineCount: 7,
            revealedLineNumbers: [],
            contextRenderID: 1
        )
        scrollView.display(
            groups: [makeGroup(includesSecondHunk: true, contextGaps: [initialGap])],
            layout: .sideBySide,
            scrollTarget: nil
        )
        scrollView.layoutSubtreeIfNeeded()

        scrollView.loadingContextGapIDs = [initialGap.id]
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        let loadingButton = try XCTUnwrap(
            (0..<tableView.numberOfRows).lazy.compactMap { row in
                tableView.view(atColumn: 0, row: row, makeIfNecessary: true)
            }.flatMap { self.descendants(of: $0) }
                .compactMap { $0 as? NSButton }
                .first {
                    $0.identifier?.rawValue == "hunk-context-expand" && !$0.isHidden
                }
        )
        XCTAssertFalse(loadingButton.isEnabled)
        XCTAssertEqual(loadingButton.accessibilityLabel(), "Loading hidden lines…")
        XCTAssertEqual(scrollView.rowRebuildCount, 1)

        let sourceOnlyGap = makeContextGap(
            hiddenLineCount: 7,
            revealedLineNumbers: [],
            contextRenderID: 2
        )
        scrollView.display(
            groups: [makeGroup(includesSecondHunk: true, contextGaps: [sourceOnlyGap])],
            layout: .sideBySide,
            scrollTarget: nil
        )
        XCTAssertEqual(scrollView.rowRebuildCount, 1)

        let revealedGap = makeContextGap(
            hiddenLineCount: 6,
            revealedLineNumbers: [9],
            contextRenderID: 2
        )
        scrollView.display(
            groups: [makeGroup(includesSecondHunk: true, contextGaps: [revealedGap])],
            layout: .sideBySide,
            scrollTarget: nil
        )
        XCTAssertEqual(scrollView.rowRebuildCount, 2)
    }

    func testWholeFileRoundTripPreservesEachHunksHorizontalOffset() throws {
        let scrollView = makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 760, height: 600)
        let firstLine = "let firstGeneratedSymbol = "
            + String(repeating: "first_namespace_component_", count: 32)
        let secondLine = "let secondGeneratedSymbol = "
            + String(repeating: "second_namespace_component_", count: 32)
        let initialGap = makeContextGap(hiddenLineCount: 7, revealedLineNumbers: [])
        let expandedGap = makeContextGap(hiddenLineCount: 4, revealedLineNumbers: [7, 8, 9])
        var showsWholeFile = false
        scrollView.onToggleWholeFile = { _ in
            showsWholeFile.toggle()
            scrollView.display(
                groups: [
                    self.makeGroup(
                        includesSecondHunk: true,
                        showsWholeFile: showsWholeFile,
                        contextGaps: [showsWholeFile ? expandedGap : initialGap],
                        additionContent: firstLine,
                        secondAdditionContent: secondLine,
                        canToggleWholeFile: true
                    )
                ],
                layout: .sideBySide,
                scrollTarget: nil
            )
        }
        scrollView.display(
            groups: [
                makeGroup(
                    includesSecondHunk: true,
                    contextGaps: [initialGap],
                    additionContent: firstLine,
                    secondAdditionContent: secondLine,
                    canToggleWholeFile: true
                )
            ],
            layout: .sideBySide,
            scrollTarget: nil
        )
        scrollView.layoutSubtreeIfNeeded()
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        let first = try codeRegion(containing: firstLine, in: tableView)
        let second = try codeRegion(containing: secondLine, in: tableView)
        XCTAssertTrue(
            scrollView.scrollCodeHorizontally(by: -180, atTablePoint: first.tablePoint)
        )
        XCTAssertTrue(
            scrollView.scrollCodeHorizontally(by: -90, atTablePoint: second.tablePoint)
        )
        first.cell.layoutSubtreeIfNeeded()
        second.cell.layoutSubtreeIfNeeded()
        let firstOffset = first.content.frame.minX
        let secondOffset = second.content.frame.minX

        for targetState in [true, false] {
            let buttonIdentifier = targetState
                ? "hunk-whole-file-toggle"
                : "whole-file-toggle"
            if targetState {
                let hunkCell = try XCTUnwrap(
                    descendants(of: scrollView).first {
                        $0.identifier?.rawValue == "diff-hunk"
                    }
                )
                _ = try revealHunkWholeFileButton(in: hunkCell)
            }
            let wholeFileButton = try XCTUnwrap(
                descendants(of: scrollView).compactMap { $0 as? NSButton }.first {
                    $0.identifier?.rawValue == buttonIdentifier && !$0.isHidden
                }
            )
            wholeFileButton.performClick(nil)
            XCTAssertEqual(showsWholeFile, targetState)
            scrollView.layoutSubtreeIfNeeded()
            let currentFirst = try codeRegion(containing: firstLine, in: tableView)
            let currentSecond = try codeRegion(containing: secondLine, in: tableView)
            currentFirst.cell.layoutSubtreeIfNeeded()
            currentSecond.cell.layoutSubtreeIfNeeded()
            XCTAssertEqual(currentFirst.content.frame.minX, firstOffset, accuracy: 0.5)
            XCTAssertEqual(currentSecond.content.frame.minX, secondOffset, accuracy: 0.5)
        }
    }

    func testCollapsingAndReopeningFilePreservesHunkHorizontalOffset() throws {
        let scrollView = makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 760, height: 600)
        let longLine = "let generatedSymbol = "
            + String(repeating: "namespace_component_", count: 32)
        scrollView.display(
            groups: [makeGroup(additionContent: longLine)],
            layout: .sideBySide,
            scrollTarget: nil
        )
        scrollView.layoutSubtreeIfNeeded()
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        let expanded = try codeRegion(containing: longLine, in: tableView)
        XCTAssertTrue(
            scrollView.scrollCodeHorizontally(by: -180, atTablePoint: expanded.tablePoint)
        )
        expanded.cell.layoutSubtreeIfNeeded()
        let offset = expanded.content.frame.minX

        scrollView.display(
            groups: [makeGroup(isFileExpanded: false, additionContent: longLine)],
            layout: .sideBySide,
            scrollTarget: nil
        )
        scrollView.layoutSubtreeIfNeeded()
        XCTAssertEqual(tableView.numberOfRows, 2)

        scrollView.display(
            groups: [makeGroup(additionContent: longLine)],
            layout: .sideBySide,
            scrollTarget: nil
        )
        scrollView.layoutSubtreeIfNeeded()
        let reopened = try codeRegion(containing: longLine, in: tableView)
        reopened.cell.layoutSubtreeIfNeeded()

        XCTAssertEqual(reopened.content.frame.minX, offset, accuracy: 0.5)
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

    func testBackgroundPresentationChangesPreserveScrollOffset() throws {
        let scrollView = makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 90)
        let suiteName = "DiffStackViewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = ReviewStateStore(defaults: defaults)
        let key = ReviewStateKey(worktreeID: "/background", context: .pending)
        scrollView.bind(store: store, key: key)
        scrollView.display(
            groups: [makeGroup()],
            layout: .sideBySide,
            scrollTarget: nil
        )
        scrollView.layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 30))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        XCTAssertEqual(store.scrollOffset(for: key), 30, accuracy: 0.5)
        let initialRebuildCount = scrollView.rowRebuildCount

        scrollView.isApplicationActive = false
        scrollView.mutationActionsEnabled = false
        XCTAssertEqual(scrollView.rowRebuildCount, initialRebuildCount)
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        let fileCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 1, makeIfNecessary: true)
        )
        let hunkCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 2, makeIfNecessary: true)
        )
        XCTAssertTrue(
            descendants(of: fileCell).compactMap { $0 as? NSButton }
                .first { $0.title == "Stage" }?.isEnabled == false
        )
        XCTAssertTrue(
            descendants(of: hunkCell).compactMap { $0 as? NSButton }
                .first { $0.title == "Stage Hunk" }?.isEnabled == false
        )

        scrollView.display(
            groups: [
                makeGroup(
                    canOpenWorkingFile: false,
                    canOpenInVisualStudioCode: false,
                    isMutationEnabled: false
                )
            ],
            layout: .sideBySide,
            scrollTarget: nil
        )
        scrollView.layoutSubtreeIfNeeded()
        XCTAssertEqual(scrollView.rowRebuildCount, initialRebuildCount)
        XCTAssertEqual(scrollView.contentView.bounds.minY, 30, accuracy: 0.5)
        XCTAssertEqual(store.scrollOffset(for: key), 30, accuracy: 0.5)

        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 10))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        XCTAssertEqual(store.scrollOffset(for: key), 30, accuracy: 0.5)

        scrollView.isApplicationActive = true
        scrollView.mutationActionsEnabled = true
        scrollView.display(
            groups: [makeGroup()],
            layout: .sideBySide,
            scrollTarget: nil
        )
        scrollView.layoutSubtreeIfNeeded()
        XCTAssertEqual(scrollView.rowRebuildCount, initialRebuildCount)
        XCTAssertEqual(scrollView.contentView.bounds.minY, 30, accuracy: 0.5)
        XCTAssertEqual(store.scrollOffset(for: key), 30, accuracy: 0.5)
    }

    func testStructuralRefreshKeepsVisibleCodeAtSameViewportPosition() throws {
        let scrollView = makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 100)
        let secondContent = "let stableViewportAnchor = 42"
        let firstCollapsed = try XCTUnwrap(
            makeGroup(id: "first", isFileExpanded: false).files.first
        )
        let firstExpanded = try XCTUnwrap(
            makeGroup(id: "first", isFileExpanded: true).files.first
        )
        let second = try XCTUnwrap(
            makeGroup(
                id: "second",
                path: "Sources/Second.swift",
                additionContent: secondContent
            ).files.first
        )
        func group(first: DiffStackFile) -> DiffStackGroup {
            DiffStackGroup(
                id: "working",
                title: "Working",
                emptyMessage: "No changes",
                isExpanded: true,
                files: [first, second]
            )
        }

        scrollView.display(
            groups: [group(first: firstCollapsed)],
            layout: .sideBySide,
            scrollTarget: nil
        )
        scrollView.layoutSubtreeIfNeeded()
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        var region = try codeRegion(containing: secondContent, in: tableView)
        var row = tableView.row(for: region.cell)
        let targetViewportY: CGFloat = 32
        scrollView.contentView.scroll(
            to: NSPoint(
                x: 0,
                y: tableView.rect(ofRow: row).minY - targetViewportY
            )
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let before = tableView.rect(ofRow: row).minY
            - scrollView.contentView.bounds.minY

        scrollView.display(
            groups: [group(first: firstExpanded)],
            layout: .sideBySide,
            scrollTarget: nil
        )
        scrollView.layoutSubtreeIfNeeded()
        region = try codeRegion(containing: secondContent, in: tableView)
        row = tableView.row(for: region.cell)
        let after = tableView.rect(ofRow: row).minY
            - scrollView.contentView.bounds.minY

        XCTAssertEqual(before, targetViewportY, accuracy: 0.5)
        XCTAssertEqual(after, before, accuracy: 0.5)
    }

    func testForegroundStructuralRefreshAtSummaryBoundaryKeepsAbsoluteOffset() throws {
        let scrollView = makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 220)
        let commit = GitCommit(
            oid: String(repeating: "a", count: 40),
            shortOID: "aaaaaaa",
            authorName: "Review Author",
            authoredAt: Date(timeIntervalSince1970: 100),
            parentOIDs: [String(repeating: "b", count: 40)],
            refNames: ["refs/heads/main"],
            subject: "Keep the summary boundary stable"
        )
        let summary = DiffStackSummary(
            commit: commit,
            metadata: GitCommitMetadata(
                treeOID: String(repeating: "c", count: 40),
                authorEmail: "review@example.com"
            ),
            message: """
            Keep the summary boundary stable when foreground loading finishes.

            The viewport starts inside this summary while code from the first
            visible file remains at the bottom of the same viewport.
            """,
            fileCount: 2,
            addedLineCount: 4,
            deletedLineCount: 4,
            isFileListExpanded: true
        )
        let firstCollapsed = try XCTUnwrap(
            makeGroup(id: "first", isFileExpanded: false).files.first
        )
        let firstExpanded = try XCTUnwrap(
            makeGroup(id: "first", isFileExpanded: true).files.first
        )
        let secondContent = "let summaryBoundaryAnchor = 42"
        let second = try XCTUnwrap(
            makeGroup(
                id: "second",
                path: "Sources/Second.swift",
                additionContent: secondContent
            ).files.first
        )
        func group(first: DiffStackFile) -> DiffStackGroup {
            DiffStackGroup(
                id: "working",
                title: "Working",
                emptyMessage: "No changes",
                isExpanded: true,
                files: [first, second]
            )
        }

        scrollView.display(
            summary: summary,
            groups: [group(first: firstCollapsed)],
            layout: .sideBySide,
            scrollTarget: nil
        )
        scrollView.layoutSubtreeIfNeeded()
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        let summaryBottom = tableView.rect(ofRow: 0).maxY
        let targetOffset = summaryBottom - 24
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetOffset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let code = try codeRegion(containing: secondContent, in: tableView)
        let codeRow = tableView.row(for: code.cell)
        XCTAssertLessThan(
            tableView.rect(ofRow: codeRow).minY,
            scrollView.contentView.bounds.maxY
        )
        XCTAssertLessThan(targetOffset, summaryBottom)

        scrollView.isApplicationActive = false
        scrollView.isApplicationActive = true
        scrollView.display(
            summary: summary,
            groups: [group(first: firstExpanded)],
            layout: .sideBySide,
            scrollTarget: nil
        )
        scrollView.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            scrollView.contentView.bounds.minY,
            targetOffset,
            accuracy: 0.5
        )
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
        XCTAssertEqual(sticky.frame.height, 57, accuracy: 0.5)

        let visibleHeaders = sticky.subviews
            .filter { !$0.isHidden }
            .sorted { $0.frame.minY < $1.frame.minY }
        XCTAssertEqual(visibleHeaders.count, 2)
        XCTAssertTrue(visibleHeaders.allSatisfy(\.clipsToBounds))
        XCTAssertEqual(visibleHeaders[0].frame.minY, 0, accuracy: 0.5)
        XCTAssertEqual(visibleHeaders[0].frame.height, 26, accuracy: 0.5)
        XCTAssertEqual(visibleHeaders[1].frame.minY, 26, accuracy: 0.5)
        XCTAssertEqual(visibleHeaders[1].frame.height, 31, accuracy: 0.5)

        sticky.displayIfNeeded()
        let bitmap = try XCTUnwrap(
            sticky.bitmapImageRepForCachingDisplay(in: sticky.bounds)
        )
        sticky.cacheDisplay(in: sticky.bounds, to: bitmap)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 1, y: 10)).alphaComponent, 1)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 1, y: 45)).alphaComponent, 1)

        let labels = descendants(of: sticky)
            .compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(labels.contains("Working · 1"))
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
            57,
            accuracy: 0.5
        )

        tableView.keyDown(with: try makeTabEvent(modifiers: .shift))
        XCTAssertEqual(tableView.selectedRow, 2)
        XCTAssertEqual(
            tableView.rect(ofRow: 2).minY - scrollView.contentView.bounds.minY,
            57,
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
                    if let textField = $0 as? NSTextField {
                        return textField.stringValue
                    }
                    return ($0 as? NSTextView)?.string
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

    func testSideBySideHunkHeaderUsesSectionHeadingAndRawHeaderTooltip() throws {
        let scrollView = makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 160)
        scrollView.display(groups: [makeGroup()], layout: .sideBySide, scrollTarget: nil)
        scrollView.layoutSubtreeIfNeeded()
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        let hunkCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 2, makeIfNecessary: true)
        )
        hunkCell.layoutSubtreeIfNeeded()
        let fields = hunkCell.subviews.compactMap { $0 as? NSTextField }
        let oldTitle = try XCTUnwrap(fields.first {
            $0.identifier?.rawValue == "hunk-title-old"
        })
        let newTitle = try XCTUnwrap(fields.first {
            $0.identifier?.rawValue == "hunk-title-new"
        })
        let unifiedTitle = try XCTUnwrap(fields.first {
            $0.identifier?.rawValue == "hunk-title-unified"
        })
        XCTAssertEqual(oldTitle.stringValue, "Sample.value")
        XCTAssertEqual(newTitle.stringValue, "Sample.value")
        XCTAssertEqual(oldTitle.lineBreakMode, .byTruncatingTail)
        XCTAssertEqual(newTitle.lineBreakMode, .byTruncatingTail)
        XCTAssertTrue(oldTitle.toolTip?.contains("@@") == true)
        XCTAssertTrue(newTitle.toolTip?.contains("@@") == true)
        XCTAssertTrue(unifiedTitle.isHidden)
        XCTAssertFalse(oldTitle.isHidden)
        XCTAssertFalse(newTitle.isHidden)
        XCTAssertEqual(oldTitle.frame.minX, 47, accuracy: 0.5)
        XCTAssertEqual(
            newTitle.frame.minX,
            floor(hunkCell.bounds.width / 2) + 47,
            accuracy: 0.5
        )
        let location = try XCTUnwrap(
            hunkCell.subviews.compactMap { $0 as? NSTextField }.first {
                $0.identifier?.rawValue == "hunk-location"
            }
        )
        XCTAssertEqual(location.stringValue, "−1–3  +1–2")
        XCTAssertTrue(location.isHidden)
    }

    func testNarrowSideBySideHunkHeaderPreservesSectionHeading() throws {
        let scrollView = makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 590, height: 160)
        scrollView.display(
            groups: [makeGroup()],
            layout: .sideBySide,
            scrollTarget: nil
        )
        scrollView.layoutSubtreeIfNeeded()
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        let hunkCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 2, makeIfNecessary: true)
        )
        hunkCell.layoutSubtreeIfNeeded()
        let fields = hunkCell.subviews.compactMap { $0 as? NSTextField }
        let oldTitle = try XCTUnwrap(fields.first {
            $0.identifier?.rawValue == "hunk-title-old"
        })
        let newTitle = try XCTUnwrap(fields.first {
            $0.identifier?.rawValue == "hunk-title-new"
        })
        let location = try XCTUnwrap(fields.first {
            $0.identifier?.rawValue == "hunk-location"
        })

        XCTAssertGreaterThan(oldTitle.frame.width, 40)
        XCTAssertGreaterThan(newTitle.frame.width, 40)
        XCTAssertEqual(oldTitle.stringValue, "Sample.value")
        XCTAssertEqual(newTitle.stringValue, "Sample.value")
        XCTAssertTrue(location.isHidden)
        XCTAssertEqual(tableView.rect(ofRow: 2).height, 23, accuracy: 0.5)
    }

    func testHunkWithoutSectionKeepsSublimeBlankHeaderRow() throws {
        let scrollView = makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 160)
        scrollView.display(
            groups: [makeGroup(mutationMode: nil, sectionHeading: nil)],
            layout: .sideBySide,
            scrollTarget: nil
        )
        scrollView.layoutSubtreeIfNeeded()
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        let hunkCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 2, makeIfNecessary: true)
        )
        hunkCell.layoutSubtreeIfNeeded()
        let fields = hunkCell.subviews.compactMap { $0 as? NSTextField }
        let oldTitle = try XCTUnwrap(fields.first {
            $0.identifier?.rawValue == "hunk-title-old"
        })
        let newTitle = try XCTUnwrap(fields.first {
            $0.identifier?.rawValue == "hunk-title-new"
        })

        XCTAssertEqual(oldTitle.stringValue, "")
        XCTAssertEqual(newTitle.stringValue, "")
        XCTAssertEqual(tableView.rect(ofRow: 2).height, 23, accuracy: 0.5)
        XCTAssertTrue(oldTitle.toolTip?.contains("@@") == true)
        XCTAssertTrue(newTitle.toolTip?.contains("@@") == true)
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
        let initialHunkRow = 7
        let targetViewportY: CGFloat = 82
        scrollView.contentView.scroll(
            to: NSPoint(
                x: 0,
                y: tableView.rect(ofRow: initialHunkRow).minY - targetViewportY
            )
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let hunkCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: initialHunkRow, makeIfNecessary: true)
        )
        // 展开入口现在就在这条 hunk 标题条的左端，不再是它上面单独一行。
        let expandButton = try XCTUnwrap(
            descendants(of: hunkCell).compactMap { $0 as? NSButton }.first {
                $0.identifier?.rawValue == "hunk-context-expand" && !$0.isHidden
            }
        )
        XCTAssertTrue(
            descendants(of: hunkCell).compactMap { ($0 as? NSTextField)?.stringValue }
                .contains("Sample.flag")
        )

        expandButton.performClick(nil)

        let expandedHunkRow = 10
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
                anchorViewportY = currentTableView.rect(ofRow: showsWholeFile ? 11 : 8).minY
                    - scrollView.contentView.bounds.minY
            }
            showsWholeFile.toggle()
            scrollView.display(
                groups: [
                    self.makeGroup(
                        includesSecondHunk: true,
                        showsWholeFile: showsWholeFile,
                        contextGaps: [showsWholeFile ? expandedGap : initialGap],
                        canToggleWholeFile: true
                    )
                ],
                layout: .unified,
                scrollTarget: nil
            )
        }
        scrollView.display(
            groups: [
                makeGroup(
                    includesSecondHunk: true,
                    contextGaps: [initialGap],
                    canToggleWholeFile: true
                )
            ],
            layout: .unified,
            scrollTarget: nil
        )
        scrollView.layoutSubtreeIfNeeded()
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        let initialCodeRow = 8
        let targetViewportY: CGFloat = 86
        scrollView.contentView.scroll(
            to: NSPoint(
                x: 0,
                y: tableView.rect(ofRow: initialCodeRow).minY - targetViewportY
            )
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
        scrollView.layoutSubtreeIfNeeded()
        let compactSecondHunkRow = 7
        let compactSecondHunk = try XCTUnwrap(
            tableView.view(
                atColumn: 0,
                row: compactSecondHunkRow,
                makeIfNecessary: true
            )
        )
        let wholeFileButton = try revealHunkWholeFileButton(in: compactSecondHunk)

        wholeFileButton.performClick(nil)

        let expandedCodeRow = 11
        XCTAssertLessThanOrEqual(
            abs(
                tableView.rect(ofRow: expandedCodeRow).minY
                    - scrollView.contentView.bounds.minY
                    - (try XCTUnwrap(anchorViewportY))
            ),
            4
        )

        let expandedFileHeader = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 1, makeIfNecessary: true)
        )
        let hideWholeFileButton = try XCTUnwrap(
            descendants(of: expandedFileHeader).compactMap { $0 as? NSButton }.first {
                $0.identifier?.rawValue == "whole-file-toggle" && !$0.isHidden
            }
        )
        hideWholeFileButton.performClick(nil)
        XCTAssertLessThanOrEqual(
            abs(
                tableView.rect(ofRow: 8).minY
                    - scrollView.contentView.bounds.minY
                    - (try XCTUnwrap(anchorViewportY))
            ),
            4
        )
    }

    func testWholeFileAnchorWaitsForAsyncContentBeforeRestoring() throws {
        let scrollView = makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 120)
        let initialGap = makeContextGap(hiddenLineCount: 7, revealedLineNumbers: [])
        let expandedGap = makeContextGap(
            hiddenLineCount: 4,
            revealedLineNumbers: [7, 8, 9]
        )
        scrollView.onToggleWholeFile = { _ in
            scrollView.display(
                groups: [
                    self.makeGroup(
                        includesSecondHunk: true,
                        showsWholeFile: true,
                        isLoadingWholeFile: true,
                        contextGaps: [initialGap],
                        canToggleWholeFile: true
                    )
                ],
                layout: .unified,
                scrollTarget: nil
            )
            scrollView.display(
                groups: [
                    self.makeGroup(
                        includesSecondHunk: true,
                        showsWholeFile: true,
                        contextGaps: [expandedGap],
                        canToggleWholeFile: true
                    )
                ],
                layout: .unified,
                scrollTarget: nil
            )
        }
        scrollView.display(
            groups: [
                makeGroup(
                    includesSecondHunk: true,
                    contextGaps: [initialGap],
                    canToggleWholeFile: true
                )
            ],
            layout: .unified,
            scrollTarget: nil
        )
        scrollView.layoutSubtreeIfNeeded()
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        let targetViewportY: CGFloat = 82
        scrollView.contentView.scroll(
            to: NSPoint(
                x: 0,
                y: tableView.rect(ofRow: 8).minY - targetViewportY
            )
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let secondHunk = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 7, makeIfNecessary: true)
        )
        let expandButton = try revealHunkWholeFileButton(in: secondHunk)

        expandButton.performClick(nil)

        XCTAssertEqual(
            tableView.rect(ofRow: 11).minY - scrollView.contentView.bounds.minY,
            targetViewportY,
            accuracy: 0.5
        )
    }

    func testCollapsingWholeFileKeepsVisibleChangedHunkAfterScrolling() throws {
        let scrollView = makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 120)
        let initialGap = makeContextGap(hiddenLineCount: 7, revealedLineNumbers: [])
        let expandedGap = makeContextGap(
            hiddenLineCount: 4,
            revealedLineNumbers: [7, 8, 9]
        )
        var showsWholeFile = false
        scrollView.onToggleWholeFile = { _ in
            showsWholeFile.toggle()
            scrollView.display(
                groups: [
                    self.makeGroup(
                        includesSecondHunk: true,
                        showsWholeFile: showsWholeFile,
                        contextGaps: [showsWholeFile ? expandedGap : initialGap],
                        canToggleWholeFile: true
                    )
                ],
                layout: .unified,
                scrollTarget: nil
            )
        }
        scrollView.display(
            groups: [
                makeGroup(
                    includesSecondHunk: true,
                    contextGaps: [initialGap],
                    canToggleWholeFile: true
                )
            ],
            layout: .unified,
            scrollTarget: nil
        )
        scrollView.layoutSubtreeIfNeeded()
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        let firstHunk = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 2, makeIfNecessary: true)
        )
        let expandButton = try revealHunkWholeFileButton(in: firstHunk)
        expandButton.performClick(nil)

        let targetViewportY: CGFloat = 82
        scrollView.contentView.scroll(
            to: NSPoint(
                x: 0,
                y: tableView.rect(ofRow: 12).minY - targetViewportY
            )
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
        scrollView.layoutSubtreeIfNeeded()
        let expandedFileHeader = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 1, makeIfNecessary: true)
        )
        let collapseButton = try XCTUnwrap(
            descendants(of: expandedFileHeader).compactMap { $0 as? NSButton }.first {
                $0.identifier?.rawValue == "whole-file-toggle" && !$0.isHidden
            }
        )

        collapseButton.performClick(nil)

        XCTAssertEqual(
            tableView.rect(ofRow: 9).minY - scrollView.contentView.bounds.minY,
            targetViewportY,
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
            descendants(of: cell).compactMap { $0 as? NSTextView }
                .first { $0.string == "let newValue = 2" }
        )
        XCTAssertTrue(content.isSelectable)

        let text = NSAttributedString(
            attributedString: try XCTUnwrap(content.textStorage)
        )
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
        let fileStage = try XCTUnwrap(fileButtons.first { $0.title == "Stage" })
        let fileDiscard = try XCTUnwrap(fileButtons.first { $0.title == "Discard" })
        XCTAssertTrue(fileStage.isHidden)
        XCTAssertTrue(fileDiscard.isHidden)
        fileCell.mouseEntered(with: try makeMouseMoveEvent())
        XCTAssertFalse(fileStage.isHidden)
        XCTAssertFalse(fileDiscard.isHidden)
        fileStage.performClick(nil)
        XCTAssertEqual(focusedFileID, "sample")
        XCTAssertEqual(fileAction, .stage)
        fileAction = nil
        fileDiscard.performClick(nil)
        XCTAssertNil(fileAction)
        XCTAssertEqual(fileDiscard.title, "Confirm")
        XCTAssertEqual(fileDiscard.accessibilityLabel(), "Confirm Discard File")
        fileDiscard.performClick(nil)
        XCTAssertEqual(fileAction, .discard)
        XCTAssertEqual(fileDiscard.title, "Discard")
        XCTAssertEqual(fileDiscard.accessibilityLabel(), "Discard File")

        let hunkCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 2, makeIfNecessary: true)
        )
        let hunkButtons = hunkCell.subviews.compactMap { $0 as? NSButton }
        let hunkStage = try XCTUnwrap(hunkButtons.first { $0.title == "Stage Hunk" })
        let hunkDiscard = try XCTUnwrap(hunkButtons.first { $0.title == "Discard" })
        XCTAssertTrue(hunkStage.isHidden)
        XCTAssertTrue(hunkDiscard.isHidden)
        hunkCell.mouseEntered(with: try makeMouseMoveEvent())
        XCTAssertFalse(hunkStage.isHidden)
        XCTAssertFalse(hunkDiscard.isHidden)
        focusedFileID = nil
        hunkStage.performClick(nil)
        XCTAssertEqual(focusedFileID, "sample")
        XCTAssertEqual(hunkAction, .stage)
        hunkAction = nil
        hunkDiscard.performClick(nil)
        XCTAssertNil(hunkAction)
        XCTAssertEqual(hunkDiscard.title, "Confirm")
        XCTAssertEqual(hunkDiscard.accessibilityLabel(), "Confirm Discard Hunk")
        hunkDiscard.performClick(nil)
        XCTAssertEqual(hunkAction, .discard)
        XCTAssertEqual(hunkDiscard.title, "Discard")
        XCTAssertEqual(hunkDiscard.accessibilityLabel(), "Discard Hunk")
    }

    func testKeyboardDiscardCommandUsesFileButtonConfirmation() throws {
        let scrollView = makeScrollView()
        var actions: [GitPendingSelectionAction] = []
        scrollView.onFileAction = { _, action in actions.append(action) }
        scrollView.display(groups: [makeGroup()], layout: .unified, scrollTarget: nil)
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)

        let firstCommand = DiffStackCommand(
            id: 1,
            action: .requestFileDiscard("sample")
        )
        scrollView.perform(firstCommand)
        let fileCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 1, makeIfNecessary: true)
        )
        let discardButton = try XCTUnwrap(
            descendants(of: fileCell).compactMap { $0 as? NSButton }.first {
                $0.title == "Confirm"
            }
        )
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(discardButton.accessibilityLabel(), "Confirm Discard File")

        scrollView.display(
            groups: [makeGroup(isFocused: true)],
            layout: .unified,
            scrollTarget: nil
        )
        let focusedFileCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 1, makeIfNecessary: true)
        )
        XCTAssertNotNil(
            descendants(of: focusedFileCell).compactMap { $0 as? NSButton }.first {
                $0.title == "Confirm"
            }
        )

        scrollView.perform(firstCommand)
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(discardButton.title, "Confirm")

        scrollView.perform(
            DiffStackCommand(
                id: 2,
                action: .requestFileDiscard("sample")
            )
        )
        XCTAssertEqual(actions, [.discard])
        XCTAssertEqual(discardButton.title, "Discard")
        XCTAssertEqual(discardButton.accessibilityLabel(), "Discard File")
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

    func testDiscardConfirmationsResetWhenDiffSnapshotChanges() throws {
        let scrollView = makeScrollView()
        var fileAction: GitPendingSelectionAction?
        var hunkAction: GitPendingSelectionAction?
        scrollView.onFileAction = { _, action in fileAction = action }
        scrollView.onSelectionAction = { _, _, action in hunkAction = action }
        scrollView.display(
            groups: [makeGroup(additionContent: "let value = 1")],
            layout: .unified,
            scrollTarget: nil
        )
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        var fileCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 1, makeIfNecessary: true)
        )
        var hunkCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 2, makeIfNecessary: true)
        )
        var fileDiscard = try XCTUnwrap(
            fileCell.subviews.compactMap { $0 as? NSButton }
                .first { $0.title == "Discard" }
        )
        var hunkDiscard = try XCTUnwrap(
            hunkCell.subviews.compactMap { $0 as? NSButton }
                .first { $0.title == "Discard" }
        )
        fileDiscard.performClick(nil)
        hunkDiscard.performClick(nil)
        XCTAssertEqual(fileDiscard.title, "Confirm")
        XCTAssertEqual(hunkDiscard.title, "Confirm")

        scrollView.display(
            groups: [makeGroup(additionContent: "let value = 2")],
            layout: .unified,
            scrollTarget: nil
        )
        fileCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 1, makeIfNecessary: true)
        )
        hunkCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 2, makeIfNecessary: true)
        )
        fileDiscard = try XCTUnwrap(
            fileCell.subviews.compactMap { $0 as? NSButton }
                .first { $0.title == "Discard" }
        )
        hunkDiscard = try XCTUnwrap(
            hunkCell.subviews.compactMap { $0 as? NSButton }
                .first { $0.title == "Discard" }
        )

        fileDiscard.performClick(nil)
        hunkDiscard.performClick(nil)
        XCTAssertEqual(fileDiscard.title, "Confirm")
        XCTAssertEqual(hunkDiscard.title, "Confirm")
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
        fileCell.mouseEntered(with: try makeMouseMoveEvent())
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
        fileCell.mouseEntered(with: try makeMouseMoveEvent())
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
        XCTAssertTrue(reviewButton.isHidden)
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
        XCTAssertTrue(reviewButton.isHidden)
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

    func testHunkHeaderExpandsWholeFileAndFileHeaderCollapsesIt() throws {
        let scrollView = makeScrollView()
        var wholeFileID: String?
        scrollView.onToggleWholeFile = { wholeFileID = $0 }
        scrollView.display(
            groups: [makeGroup(canToggleWholeFile: true)],
            layout: .unified,
            scrollTarget: nil
        )
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        let compactHunkCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 2, makeIfNecessary: true)
        )
        let expandButton = try revealHunkWholeFileButton(in: compactHunkCell)
        XCTAssertEqual(expandButton.toolTip, "Show Entire File")
        XCTAssertNotNil(expandButton.image)
        expandButton.performClick(nil)
        XCTAssertEqual(wholeFileID, "sample")
        XCTAssertTrue(
            scrollView.contextMenu(
                clickedRow: 1,
                selectedRows: IndexSet(integer: 1)
            ).items.contains { $0.title == "Show Whole File" }
        )

        scrollView.display(
            groups: [makeGroup(showsWholeFile: true, canToggleWholeFile: true)],
            layout: .unified,
            scrollTarget: nil
        )
        let expandedFileHeader = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 1, makeIfNecessary: true)
        )
        let collapseButton = try XCTUnwrap(
            descendants(of: expandedFileHeader).compactMap { $0 as? NSButton }
                .first { $0.identifier?.rawValue == "whole-file-toggle" }
        )
        XCTAssertFalse(collapseButton.isHidden)
        XCTAssertEqual(collapseButton.toolTip, "Show Only Modified Hunks")
        XCTAssertNotNil(collapseButton.image)
        XCTAssertTrue(
            scrollView.contextMenu(
                clickedRow: 1,
                selectedRows: IndexSet(integer: 1)
            ).items.contains { $0.title == "Show Changed Hunks" }
        )
    }

    func testHistoricalHunkShowsRealLineHistoryActionOnlyOnHover() throws {
        let scrollView = makeScrollView()
        var requestedFileID: String?
        var requestedStartLine: Int?
        var requestedEndLine: Int?
        scrollView.onShowHunkHistory = { fileID, startLine, endLine in
            requestedFileID = fileID
            requestedStartLine = startLine
            requestedEndLine = endLine
        }
        scrollView.display(
            groups: [makeGroup(mutationMode: nil)],
            layout: .sideBySide,
            scrollTarget: nil
        )
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        let hunkCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 2, makeIfNecessary: true)
        )
        let historyButton = try XCTUnwrap(
            descendants(of: hunkCell).compactMap { $0 as? NSButton }.first {
                $0.identifier?.rawValue == "hunk-history"
            }
        )
        let menuButton = try XCTUnwrap(
            descendants(of: hunkCell).compactMap { $0 as? NSButton }.first {
                $0.identifier?.rawValue == "hunk-actions-menu"
            }
        )

        XCTAssertTrue(historyButton.isHidden)
        XCTAssertTrue(menuButton.isHidden)
        hunkCell.mouseEntered(with: try makeMouseMoveEvent())
        XCTAssertFalse(historyButton.isHidden)
        XCTAssertFalse(menuButton.isHidden)
        XCTAssertEqual(historyButton.title, "Hunk History")
        XCTAssertEqual(menuButton.accessibilityLabel(), "Hunk Actions")
        historyButton.performClick(nil)
        XCTAssertEqual(requestedFileID, "sample")
        XCTAssertEqual(requestedStartLine, 1)
        XCTAssertEqual(requestedEndLine, 2)

        hunkCell.mouseExited(with: try makeMouseMoveEvent())
        XCTAssertTrue(historyButton.isHidden)
        XCTAssertTrue(menuButton.isHidden)
    }

    func testRendersHistoricalHunkHoverControlsOffscreen() throws {
        let scrollView = makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 1_200, height: 220)
        scrollView.display(
            groups: [makeGroup(mutationMode: nil)],
            layout: .sideBySide,
            scrollTarget: nil
        )
        scrollView.layoutSubtreeIfNeeded()
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        let hunkCell = try XCTUnwrap(
            tableView.view(atColumn: 0, row: 2, makeIfNecessary: true)
        )
        hunkCell.mouseEntered(with: try makeMouseMoveEvent())
        scrollView.displayIfNeeded()

        let bitmap = try XCTUnwrap(
            scrollView.bitmapImageRepForCachingDisplay(in: scrollView.bounds)
        )
        scrollView.cacheDisplay(in: scrollView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let output = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        .appendingPathComponent(".build/verification", isDirectory: true)
        .appendingPathComponent("AgentGitHunk-history-hover.png")
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try png.write(to: output)
        XCTAssertGreaterThan(png.count, 1_000)
    }

    func testWholeFileCollapseActionRemainsInStickyFileHeader() throws {
        let scrollView = makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 90)
        var wholeFileID: String?
        scrollView.onToggleWholeFile = { wholeFileID = $0 }
        scrollView.display(
            groups: [
                makeGroup(
                    includesSecondHunk: true,
                    showsWholeFile: true,
                    canToggleWholeFile: true
                )
            ],
            layout: .unified,
            scrollTarget: nil
        )
        scrollView.layoutSubtreeIfNeeded()
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        scrollView.contentView.scroll(
            to: NSPoint(x: 0, y: tableView.rect(ofRow: 5).minY)
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
        scrollView.layoutSubtreeIfNeeded()

        let tableButtonIDs = Set(
            descendants(of: tableView).compactMap { ($0 as? NSButton).map(ObjectIdentifier.init) }
        )
        let stickyCollapseButton = try XCTUnwrap(
            descendants(of: scrollView).compactMap { $0 as? NSButton }.first {
                $0.identifier?.rawValue == "whole-file-toggle"
                    && !$0.isHidden
                    && !tableButtonIDs.contains(ObjectIdentifier($0))
            }
        )
        XCTAssertEqual(stickyCollapseButton.toolTip, "Show Only Modified Hunks")
        stickyCollapseButton.performClick(nil)
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
        let window = NSWindow(
            contentRect: scrollView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        scrollView.display(
            groups: [
                makeGroup(
                    includesSecondHunk: true,
                    contextGaps: [
                        makeContextGap(hiddenLineCount: 7, revealedLineNumbers: [])
                    ],
                    canToggleWholeFile: true
                )
            ],
            layout: .sideBySide,
            scrollTarget: nil
        )
        scrollView.layoutSubtreeIfNeeded()
        scrollView.displayIfNeeded()

        let bitmap = try XCTUnwrap(
            scrollView.bitmapImageRepForCachingDisplay(in: scrollView.bounds)
        )
        scrollView.cacheDisplay(in: scrollView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 10_000)
        XCTAssertGreaterThan(sampledColorSignatures(in: bitmap).count, 8)

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
        let window = NSWindow(
            contentRect: scrollView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = scrollView
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        scrollView.display(
            groups: [
                makeGroup(
                    includesSecondHunk: true,
                    contextGaps: [
                        makeContextGap(hiddenLineCount: 7, revealedLineNumbers: [])
                    ],
                    canToggleWholeFile: true
                )
            ],
            layout: .sideBySide,
            scrollTarget: nil
        )
        scrollView.layoutSubtreeIfNeeded()
        scrollView.displayIfNeeded()

        let bitmap = try XCTUnwrap(
            scrollView.bitmapImageRepForCachingDisplay(in: scrollView.bounds)
        )
        scrollView.cacheDisplay(in: scrollView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 10_000)
        XCTAssertGreaterThan(sampledColorSignatures(in: bitmap).count, 8)

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

    private func sampledColorSignatures(
        in bitmap: NSBitmapImageRep
    ) -> Set<String> {
        var colors: Set<String> = []
        for y in stride(from: 4, to: bitmap.pixelsHigh, by: 12) {
            for x in stride(from: 4, to: bitmap.pixelsWide, by: 12) {
                guard let color = bitmap.colorAt(x: x, y: y)?
                    .usingColorSpace(.deviceRGB) else {
                    continue
                }
                colors.insert(
                    [color.redComponent, color.greenComponent, color.blueComponent]
                        .map { String(Int(($0 * 255).rounded())) }
                        .joined(separator: ",")
                )
            }
        }
        return colors
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

    private func revealHunkWholeFileButton(in hunkCell: NSView) throws -> NSButton {
        let button = try XCTUnwrap(
            descendants(of: hunkCell).compactMap { $0 as? NSButton }.first {
                $0.identifier?.rawValue == "hunk-whole-file-toggle"
            }
        )
        XCTAssertTrue(button.isHidden)
        hunkCell.mouseEntered(with: try makeMouseMoveEvent())
        XCTAssertFalse(button.isHidden)
        return button
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
                      let textView = view as? NSTextView else {
                    return false
                }
                return textView.string == text
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

    func testOneSidedDiffFallsBackToUnifiedInSplitLayout() throws {
        // 纯新增的文件在 split 下左栏永远是空的，等于白扔半个窗口宽度，所以要退回 unified。
        let scrollView = makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 400)
        scrollView.display(
            groups: [makeAdditionOnlyGroup()],
            layout: .sideBySide,
            scrollTarget: nil
        )
        scrollView.layoutSubtreeIfNeeded()
        XCTAssertFalse(
            try hasSideBySideCodeRow(in: scrollView),
            "A file with no deletions should not render split panes"
        )

        // 有增有删的文件仍然左右对照，否则 split 就等于没有了。
        scrollView.display(
            groups: [makeGroup()],
            layout: .sideBySide,
            scrollTarget: nil
        )
        scrollView.layoutSubtreeIfNeeded()
        XCTAssertTrue(
            try hasSideBySideCodeRow(in: scrollView),
            "A file with both additions and deletions should still render split panes"
        )
    }

    private func hasSideBySideCodeRow(in scrollView: DiffStackScrollView) throws -> Bool {
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        return (0..<tableView.numberOfRows).contains { row in
            guard let cell = tableView.view(
                atColumn: 0,
                row: row,
                makeIfNecessary: true
            ) else {
                return false
            }
            return String(reflecting: type(of: cell))
                .contains("DiffSideBySideCellView")
        }
    }

    private func makeAdditionOnlyGroup() -> DiffStackGroup {
        let change = GitFileChange(
            path: "Sources/Added.swift",
            originalPath: nil,
            indexStatus: ".",
            worktreeStatus: "A",
            kind: .ordinary
        )
        let diff = GitFileDiff(
            change: change,
            scope: .working,
            hunks: [
                GitDiffHunk(
                    id: 0,
                    header: "@@ -0,0 +1,2 @@",
                    sectionHeading: nil,
                    oldStart: 0,
                    oldCount: 0,
                    newStart: 1,
                    newCount: 2,
                    lines: [
                        GitDiffLine(
                            id: 0,
                            kind: .addition,
                            oldLineNumber: nil,
                            newLineNumber: 1,
                            content: "let first = 1"
                        ),
                        GitDiffLine(
                            id: 1,
                            kind: .addition,
                            oldLineNumber: nil,
                            newLineNumber: 2,
                            content: "let second = 2"
                        )
                    ]
                )
            ],
            state: .textual
        )
        return DiffStackGroup(
            id: "working",
            title: "Working",
            emptyMessage: "No changes",
            isExpanded: true,
            files: [
                DiffStackFile(
                    id: "added",
                    path: change.path,
                    originalPath: nil,
                    status: .added,
                    statusLabel: "A",
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
                    mutationSnapshotID: DiffReviewSnapshotID(diff: diff),
                    contextGaps: [],
                    mutationMode: .working,
                    diff: diff,
                    imageDiff: nil
                )
            ]
        )
    }

    private func makeGroup(
        id: String = "sample",
        includesSecondHunk: Bool = false,
        isFileExpanded: Bool = true,
        isFocused: Bool = false,
        isReviewed: Bool = false,
        showsWholeFile: Bool = false,
        isLoadingWholeFile: Bool = false,
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
        isMutationEnabled: Bool = true,
        canToggleWholeFile: Bool = false,
        mutationMode: DiffStackMutationMode? = .working,
        sectionHeading: String? = "Sample.value"
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
                sectionHeading: sectionHeading,
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
                    isExpanded: isFileExpanded,
                    isFocused: isFocused,
                    isReviewed: isReviewed,
                    showsWholeFile: showsWholeFile,
                    isLoadingWholeFile: isLoadingWholeFile,
                    canToggleWholeFile: canToggleWholeFile || showsWholeFile,
                    canOpenWorkingFile: canOpenWorkingFile,
                    canOpenInVisualStudioCode: canOpenInVisualStudioCode,
                    canApplyPrimaryAction: canApplyPrimaryAction,
                    canDiscard: canDiscard,
                    isMutationEnabled: isMutationEnabled,
                    mutationSnapshotID: DiffReviewSnapshotID(diff: diff),
                    contextGaps: contextGaps,
                    mutationMode: mutationMode,
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
                    mutationSnapshotID: DiffReviewSnapshotID(diff: diff),
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
                    mutationSnapshotID: DiffReviewSnapshotID(diff: diff),
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
