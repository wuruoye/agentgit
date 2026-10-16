@testable import AgentGitApp
import AppKit
import SwiftUI
import Testing

@Test @MainActor func commitListDisablesTheSystemSelectionBackground() async throws {
    _ = NSApplication.shared
    let list = List(selection: Binding.constant(Set([0]))) {
        ForEach(0..<2) { index in
            Text("Commit \(index)")
                .tag(index)
                .listRowBackground(WorkspaceSelectionBackground(isSelected: index == 0))
        }
    }
    .listStyle(.sidebar)
    let host = NSHostingView(rootView: list)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
        styleMask: [.titled], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    await Task.yield()
    host.layoutSubtreeIfNeeded()

    func findTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { findTable(in: $0) }.first
    }
    let table = try #require(findTable(in: host))
    table.layoutSubtreeIfNeeded()
    #expect(table.numberOfRows == 2)
    #expect(table.selectionHighlightStyle == .none)
    table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
    await Task.yield()
    host.layoutSubtreeIfNeeded()
    #expect(table.selectionHighlightStyle == .none)
}
