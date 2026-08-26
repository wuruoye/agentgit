import AgentGitCore
import SwiftUI

struct WorktreeReviewView: View {
    let snapshot: GitWorktreeSnapshot

    var body: some View {
        IntegratedReviewWorkspace(snapshot: snapshot)
    }
}

/// ⌘↓ / ⌘↑ 在改动文件间移动，不要求文件列表持有焦点。
struct FileNavigationShortcuts: View {
    let selectNext: () -> Void
    let selectPrevious: () -> Void

    var body: some View {
        ZStack {
            Button("Next File", action: selectNext)
                .keyboardShortcut(.downArrow, modifiers: .command)
            Button("Previous File", action: selectPrevious)
                .keyboardShortcut(.upArrow, modifiers: .command)
        }
        .opacity(0)
        .accessibilityHidden(true)
    }
}
