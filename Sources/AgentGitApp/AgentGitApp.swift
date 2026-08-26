import SwiftUI

@main
struct AgentGitApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("AgentGit") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1080, minHeight: 620)
        }
        .defaultSize(width: 1440, height: 840)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Git Project…", action: model.chooseProject)
                    .keyboardShortcut("o", modifiers: .command)
            }

            CommandMenu("Project") {
                Button("Refresh All Projects") {
                    Task {
                        await model.refreshAll()
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }

        Settings {
            AgentGitSettingsView()
                .environment(model)
        }
    }
}
