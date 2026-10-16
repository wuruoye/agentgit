import AgentGitCore
@testable import AgentGitApp
import AppKit
import Testing

@Test @MainActor func expandingAnEarlierFilePushesLaterContentDown() throws {
    _ = NSApplication.shared
    for offset: CGFloat in [0, 17] {
        let scrollView = DiffStackScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 260))
        let lower = expansionScrollFile("editor.ts", expanded: true)
        func display(upperExpanded: Bool) {
            scrollView.display(
                groups: [DiffStackGroup(
                    id: "commit", title: nil, emptyMessage: "", isExpanded: true,
                    files: [expansionScrollFile("editor.test.ts", expanded: upperExpanded), lower]
                )],
                layout: .unified, scrollTarget: nil
            )
            scrollView.layoutSubtreeIfNeeded()
        }
        display(upperExpanded: false)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
        let table = try #require(scrollView.documentView as? NSTableView)
        let lowerHeaderBefore = table.rect(ofRow: 1).minY

        display(upperExpanded: true)

        #expect(abs(scrollView.contentView.bounds.minY - offset) < 0.5)
        #expect(table.rect(ofRow: 32).minY > lowerHeaderBefore + 500)
    }
}

@MainActor private func expansionScrollFile(_ path: String, expanded: Bool) -> DiffStackFile {
    let change = GitFileChange(
        path: path, originalPath: nil, indexStatus: "A", worktreeStatus: ".", kind: .ordinary
    )
    let lines = (1...30).map {
        GitDiffLine(id: $0, kind: .addition, oldLineNumber: nil, newLineNumber: $0, content: "line \($0)")
    }
    let diff = GitFileDiff(change: change, scope: .working, hunks: [GitDiffHunk(
        id: 0, header: "@@ -0,0 +1,30 @@", oldStart: 0, oldCount: 0,
        newStart: 1, newCount: 30, lines: lines
    )], state: .textual)
    return DiffStackFile(
        id: path, path: path, originalPath: nil, status: .added, statusLabel: "A",
        isExpanded: expanded, isFocused: false, isReviewed: false,
        showsWholeFile: false, isLoadingWholeFile: false, canToggleWholeFile: false,
        canOpenWorkingFile: false, canOpenInVisualStudioCode: false,
        canApplyPrimaryAction: false, canDiscard: false, isMutationEnabled: false,
        mutationSnapshotID: nil, contextGaps: [], mutationMode: nil, diff: diff, imageDiff: nil
    )
}
