import AppKit
import SwiftUI

enum AgentGitWindowMetrics {
    static let minimumWidth: CGFloat = 980
    static let minimumHeight: CGFloat = 600
    static let defaultWidth: CGFloat = 1_440
    static let defaultHeight: CGFloat = 840
}

@main
struct AgentGitApp: App {
    @NSApplicationDelegateAdaptor(AgentGitApplicationDelegate.self)
    private var applicationDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("AgentGit") {
            ContentView()
                .environment(model)
                .frame(
                    minWidth: AgentGitWindowMetrics.minimumWidth,
                    minHeight: AgentGitWindowMetrics.minimumHeight
                )
                .onAppear {
                    applicationDelegate.attach(model)
                }
        }
        .defaultSize(
            width: AgentGitWindowMetrics.defaultWidth,
            height: AgentGitWindowMetrics.defaultHeight
        )
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            AgentGitReviewCommands()

            CommandGroup(replacing: .newItem) {
                Button("Add Git Project…", action: model.chooseProject)
                    .keyboardShortcut("o", modifiers: .command)
            }

            CommandMenu("Project") {
                Button("Switch Worktree…") {
                    model.isWorktreeSwitcherPresented = true
                }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(!model.hasAvailableWorktrees)

                Divider()

                Button("Refresh Current Worktree") {
                    Task {
                        await model.refreshSelectedWorktree()
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.selectedWorktree == nil)

                Button("Refresh All Projects") {
                    Task {
                        await model.refreshAll()
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            AgentGitSettingsView()
                .environment(model)
        }
    }
}

@MainActor
final class AgentGitApplicationDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var isPreparingTermination = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard let appearanceName = requestedVisualTestAppearance(
            environment: ProcessInfo.processInfo.environment
        ) else {
            return
        }
        NSApp.appearance = NSAppearance(named: appearanceName)
    }

    func attach(_ model: AppModel) {
        self.model = model
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard let model else {
            return .terminateNow
        }
        guard !isPreparingTermination else {
            return .terminateLater
        }
        isPreparingTermination = true
        Task {
            await model.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

func requestedVisualTestAppearance(
    environment: [String: String]
) -> NSAppearance.Name? {
    switch environment["AGENTGIT_VISUAL_TEST_APPEARANCE"]?.lowercased() {
    case "light": .aqua
    case "dark": .darkAqua
    default: nil
    }
}
