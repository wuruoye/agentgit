@testable import AgentGitApp
import AgentGitCore
import AppKit
import Foundation
import Testing

@MainActor
private func stickyTestFile(_ path: String, lineCount: Int) -> DiffStackFile {
    let change = GitFileChange(path: path, originalPath: nil, indexStatus: ".", worktreeStatus: "A", kind: .ordinary)
    let lines = (1...lineCount).map {
        GitDiffLine(id: $0, kind: .addition, oldLineNumber: nil, newLineNumber: $0, content: "let v\($0) = \($0)")
    }
    let diff = GitFileDiff(
        change: change,
        scope: .working,
        hunks: [GitDiffHunk(id: 0, header: "@@ -0,0 +1,\(lineCount) @@", oldStart: 0, oldCount: 0,
                            newStart: 1, newCount: lineCount, lines: lines)],
        state: .textual
    )
    return DiffStackFile(
        id: path, path: path, originalPath: nil, status: .added, statusLabel: "A",
        isExpanded: true, isFocused: false, isReviewed: false, showsWholeFile: false,
        isLoadingWholeFile: false, canToggleWholeFile: false, canOpenWorkingFile: false,
        canOpenInVisualStudioCode: false, canApplyPrimaryAction: false, canDiscard: false,
        isMutationEnabled: false, mutationSnapshotID: nil, contextGaps: [], mutationMode: nil,
        diff: diff, imageDiff: nil
    )
}

@MainActor
private func allDescendants(of view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap { allDescendants(of: $0) }
}

/// 几万行时 AppKit 对还没排到的行先按估算位置摆放。吸顶标题要跟着表格实际排出来的行走：
/// 下一个文件标题顶上来时，上一个文件的吸顶标题只能露出到它的顶边。
@Test @MainActor func stickyFileHeaderFollowsTableLayoutInLargeDiffs() throws {
    _ = NSApplication.shared
    let lineCounts = [729, 9, 2, 746, 10, 300, 1, 40]
    let files = (0..<160).map { index in
        stickyTestFile("lib/dir\(index % 7)/file\(index).dart", lineCount: lineCounts[index % lineCounts.count])
    }
    let scrollView = DiffStackScrollView(frame: NSRect(x: 0, y: 0, width: 1200, height: 700))
    let table = try #require(scrollView.documentView as? NSTableView)
    scrollView.display(
        groups: [DiffStackGroup(id: "context", title: nil, emptyMessage: "", isExpanded: true, files: files)],
        layout: .unified,
        scrollTarget: nil
    )
    scrollView.layoutSubtreeIfNeeded()
    let fileHeaderHeight = ReviewWorkspaceStyle.fileHeaderHeight
    let headerRows = (0..<table.numberOfRows).filter {
        scrollView.tableView(table, heightOfRow: $0) == fileHeaderHeight
    }
    #expect(headerRows.count == files.count)
    #expect(table.numberOfRows > 30_000)
    let sticky = try #require(scrollView.subviews.first {
        String(describing: type(of: $0)) == "DiffStickyClipView"
    })

    var problems: [String] = []
    for index in stride(from: 1, to: headerRows.count, by: 3) {
        for delta in [CGFloat(30), 12, 2] {
            let top = table.rect(ofRow: headerRows[index]).minY - delta
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: top))
            scrollView.layoutSubtreeIfNeeded()
            // 滚动后表格可能把估算位置换成实际位置，按此刻的排布判断。
            let currentTop = scrollView.contentView.bounds.minY
            let gap = table.rect(ofRow: headerRows[index]).minY - currentTop
            let expectedHeight = min(fileHeaderHeight, max(0, gap))
            let shownHeight = sticky.isHidden ? 0 : sticky.frame.height
            let shownNames = sticky.isHidden ? [] : allDescendants(of: sticky)
                .filter { !$0.isHiddenOrHasHiddenAncestor }
                .compactMap { ($0 as? NSTextField)?.stringValue }
                .filter { $0.hasSuffix(".dart") }
            let expectedName = (files[index - 1].path as NSString).lastPathComponent
            if abs(shownHeight - expectedHeight) > 0.5
                || (expectedHeight > 1 && shownNames != [expectedName]) {
                problems.append("file \(index) delta \(delta): shown \(shownNames) h \(shownHeight), expected \(expectedName) h \(expectedHeight)")
            }
        }
    }
    #expect(problems.isEmpty, "\(problems.count) problems: \(problems.prefix(5))")
}

@Test @MainActor func visibleFileFollowsScrollAndStaysOnJumpTarget() async throws {
    _ = NSApplication.shared
    let files = [
        stickyTestFile("First.swift", lineCount: 40),
        stickyTestFile("Second.swift", lineCount: 40),
        stickyTestFile("Last.swift", lineCount: 2)
    ]
    let scrollView = DiffStackScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
    let table = try #require(scrollView.documentView as? NSTableView)
    var reports: [(String, Bool)] = []
    scrollView.onVisibleFileChanged = { reports.append(($0, $1)) }
    scrollView.display(
        groups: [DiffStackGroup(id: "context", title: nil, emptyMessage: "", isExpanded: true, files: files)],
        layout: .unified,
        scrollTarget: nil
    )
    scrollView.layoutSubtreeIfNeeded()
    let headerRows = (0..<table.numberOfRows).filter {
        scrollView.tableView(table, heightOfRow: $0) == ReviewWorkspaceStyle.fileHeaderHeight
    }
    #expect(headerRows.count == 3)

    scrollView.contentView.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: headerRows[1]).minY + 10))
    try await Task.sleep(for: .milliseconds(50))
    #expect(reports.last?.0 == "Second.swift")
    #expect(reports.last?.1 == true)

    // Last.swift 很短，跳过去后标题到不了顶部，顶部仍是 Second.swift，但要一直报跳转目标。
    reports.removeAll()
    scrollView.perform(DiffStackCommand(id: 1, action: .focusFile("Last.swift")))
    scrollView.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(50))
    #expect(!reports.contains { $0.0 != "Last.swift" })

    // 用户自己跳 hunk 后恢复按顶部位置报。
    #expect(scrollView.moveHunk(by: -1))
    try await Task.sleep(for: .milliseconds(50))
    let topFile = try #require(reports.last?.0)
    #expect(topFile == "First.swift" || topFile == "Second.swift")
}
