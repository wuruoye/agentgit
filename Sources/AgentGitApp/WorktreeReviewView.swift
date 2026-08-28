import AgentGitCore
import SwiftUI

struct WorktreeReviewView: View {
    @Environment(AppModel.self) private var model

    let snapshot: GitWorktreeSnapshot

    var body: some View {
        let initialNavigationState = model.reviewStates.lastContext(
            for: snapshot.id
        )
        let startupContent = model.startupReviewContent(for: snapshot)
        let restoresInitialContext = if initialNavigationState.context == .pending {
            true
        } else if GitHistorySearchQuery(initialNavigationState.historyFilter) != nil {
            false
        } else {
            startupContent?.historyPage.map {
                restoredHistorySelection(
                    initialNavigationState,
                    commits: $0.commits
                ) != nil
            } ?? false
        }
        let initialStateContext = restoresInitialContext
            ? initialNavigationState.context
            : .pending
        IntegratedReviewWorkspace(
            snapshot: snapshot,
            startupContent: startupContent,
            initialContext: initialNavigationState.context,
            initialSelectedCommitIDs: initialNavigationState.selectedCommitIDs,
            initialPane: initialNavigationState.pane,
            initialHistoryFilter: initialNavigationState.historyFilter,
            initialReviewState: model.reviewStates.state(
                for: ReviewStateKey(
                    worktreeID: snapshot.id,
                    context: initialStateContext
                )
            )
        )
    }
}

struct ReviewCommandActions {
    let navigateBack: () -> Void
    let navigateForward: () -> Void
    let canNavigateBack: Bool
    let canNavigateForward: Bool
    let selectNext: () -> Void
    let selectPrevious: () -> Void
    let focusFilter: () -> Void
    let showCommits: () -> Void
    let showFiles: () -> Void
}

private struct ReviewCommandActionsKey: FocusedValueKey {
    typealias Value = ReviewCommandActions
}

extension FocusedValues {
    var reviewCommandActions: ReviewCommandActions? {
        get { self[ReviewCommandActionsKey.self] }
        set { self[ReviewCommandActionsKey.self] = newValue }
    }
}

struct AgentGitReviewCommands: Commands {
    @FocusedValue(\.reviewCommandActions) private var actions

    var body: some Commands {
        CommandMenu("Review") {
            Button("Navigate Back") {
                actions?.navigateBack()
            }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(actions?.canNavigateBack != true)
            Button("Navigate Forward") {
                actions?.navigateForward()
            }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(actions?.canNavigateForward != true)

            Divider()

            Button("Next File") {
                actions?.selectNext()
            }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(actions == nil)
            Button("Previous File") {
                actions?.selectPrevious()
            }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(actions == nil)

            Divider()

            Button("Focus Filter") {
                actions?.focusFilter()
            }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(actions == nil)

            Divider()

            Button("Show Commits") {
                actions?.showCommits()
            }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(actions == nil)
            Button("Show Files") {
                actions?.showFiles()
            }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(actions == nil)
        }
    }
}
