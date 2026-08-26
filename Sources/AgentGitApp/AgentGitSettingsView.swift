import AgentGitCore
import SwiftUI

struct AgentGitSettingsView: View {
    @Environment(AppModel.self) private var model

    private static let contextChoices: [GitDiffContext] = [
        .lines(3), .lines(8), .lines(25), .wholeFile
    ]

    var body: some View {
        Form {
            Section("Diff") {
                Picker("Layout", selection: layoutBinding) {
                    ForEach(DiffLayoutMode.allCases) { layout in
                        Text(layout.title).tag(layout)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Context", selection: contextBinding) {
                    ForEach(Self.contextChoices, id: \.self) { context in
                        Text(context.title).tag(context)
                    }
                }

                Toggle("Ignore whitespace changes", isOn: ignoresWhitespaceBinding)
            }

            Text("These settings apply to every worktree and commit review.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding(12)
        .frame(width: 460, height: 230)
    }

    private var layoutBinding: Binding<DiffLayoutMode> {
        Binding(
            get: { model.diffLayout },
            set: { model.diffLayout = $0 }
        )
    }

    private var contextBinding: Binding<GitDiffContext> {
        Binding(
            get: { model.diffOptions.context },
            set: { context in
                var options = model.diffOptions
                options.context = context
                model.diffOptions = options
            }
        )
    }

    private var ignoresWhitespaceBinding: Binding<Bool> {
        Binding(
            get: { model.diffOptions.ignoresWhitespace },
            set: { ignoresWhitespace in
                var options = model.diffOptions
                options.ignoresWhitespace = ignoresWhitespace
                model.diffOptions = options
            }
        )
    }
}
