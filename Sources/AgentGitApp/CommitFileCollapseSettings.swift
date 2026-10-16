import AgentGitCore
import Foundation
import Observation

@MainActor
@Observable
final class CommitFileCollapseSettings {
    private static let persistenceKey = "agentgit.commit-file-collapse-rules-by-project"
    private static let legacyKey = "agentgit.commit-file-collapse-rules"
    private let defaults: UserDefaults
    private var textByProjectID: [GitProject.ID: String]
    @ObservationIgnored private var compiledByProjectID: [GitProject.ID: CommitFileCollapseRules]

    init(defaults: UserDefaults, legacyProjectID: GitProject.ID? = nil) {
        self.defaults = defaults
        var texts = defaults.dictionary(forKey: Self.persistenceKey) as? [String: String] ?? [:]
        if let legacyProjectID,
           let text = defaults.string(forKey: Self.legacyKey),
           !text.isEmpty,
           texts[legacyProjectID] == nil {
            texts[legacyProjectID] = text
            defaults.set(texts, forKey: Self.persistenceKey)
        }
        if legacyProjectID != nil || defaults.string(forKey: Self.legacyKey) == "" {
            defaults.removeObject(forKey: Self.legacyKey)
        }
        textByProjectID = texts
        compiledByProjectID = texts.mapValues(CommitFileCollapseRules.init)
    }

    func text(for projectID: GitProject.ID) -> String {
        textByProjectID[projectID] ?? ""
    }

    func rules(for projectID: GitProject.ID) -> CommitFileCollapseRules {
        // 读取可观察的文本，让当前仓库的规则修改触发 Review 更新。
        _ = textByProjectID[projectID]
        return compiledByProjectID[projectID] ?? CommitFileCollapseRules("")
    }

    func setText(_ text: String, for projectID: GitProject.ID) {
        guard text != self.text(for: projectID) else { return }
        if text.isEmpty {
            textByProjectID.removeValue(forKey: projectID)
            compiledByProjectID.removeValue(forKey: projectID)
        } else {
            textByProjectID[projectID] = text
            compiledByProjectID[projectID] = CommitFileCollapseRules(text)
        }
        defaults.set(textByProjectID, forKey: Self.persistenceKey)
    }

    /// 项目解析为主 checkout 时，规则跟随同一仓库的项目 ID。
    func moveRules(from originalID: GitProject.ID, to resolvedID: GitProject.ID) {
        guard originalID != resolvedID, let text = textByProjectID[originalID] else { return }
        if textByProjectID[resolvedID] == nil {
            setText(text, for: resolvedID)
        }
        setText("", for: originalID)
    }
}
