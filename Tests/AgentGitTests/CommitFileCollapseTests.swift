import AgentGitCore
@testable import AgentGitApp
import Testing
import Foundation

@Test func collapseRuleMatching() {
    let cases: [(String, String, Bool)] = [
        ("*.lock", "deps/package.lock", true),
        ("*.lock", "deps/package.lock.swift", false),
        ("*.lock", "deps/PACKAGE.LOCK", false),
        ("Sources/*.swift", "Sources/Main.swift", true),
        ("Sources/*.swift", "Sources/Nested/Main.swift", false),
        ("Sources/*.swift", "Other/Sources/Main.swift", false),
        ("**/generated/**", "generated/Model.swift", true),
        ("**/generated/**", "Sources/generated/deep/Model.swift", true),
        ("**/generated/**", "Sources/Model.swift", false),
        ("generated/", "generated/deep/Model.swift", true),
        ("generated/", "Sources/generated/Model.swift", false),
        ("Sources/**/Model.swift", "Sources/Model.swift", true),
        ("Sources/**/Model.swift", "Sources/a/b/Model.swift", true),
        ("file?.txt", "dir/file1.txt", true),
        ("file?.txt", "dir/file12.txt", false),
        ("/README.md", "README.md", true),
        ("/README.md", "docs/README.md", false),
        ("./README.md", "README.md", true),
        ("file[1].txt", "dir/file[1].txt", true),
        ("文件?.txt", "目录/文件一.txt", true),
        (" \r\n# comment\r\n  *.lock  \r\n*.pb.swift", "a/model.pb.swift", true),
        (" \n# *.swift", "Model.swift", false),
        ("", "anything", false)
    ]
    for (rule, path, expected) in cases {
        #expect(CommitFileCollapseRules(rule).matches(path) == expected,
                "Rule: \(rule), path: \(path)")
    }
}

@Test func commitCollapseDefaultsAndManualExpansion() {
    var state = ReviewState()
    let fileIDs: Set<String> = ["code", "generated"]
    synchronizeReviewFileExpansion(
        in: &state, fileIDs: fileIDs, automaticExpansionLimit: 20,
        defaultCollapsedFileIDs: ["generated", "absent"]
    )
    #expect(state.collapsedFileIDs == ["generated"])
    #expect(isReviewFileExpanded("code", in: state))

    toggleReviewFileExpansion(in: &state, fileID: "generated")
    #expect(isReviewFileExpanded("generated", in: state))

    // 再次打开已有提交时，规则也会应用到已知文件。
    synchronizeReviewFileExpansion(
        in: &state, fileIDs: fileIDs, automaticExpansionLimit: 20,
        defaultCollapsedFileIDs: ["generated"]
    )
    #expect(!isReviewFileExpanded("generated", in: state))

    var pending = ReviewState()
    synchronizeReviewFileExpansion(in: &pending, fileIDs: fileIDs, automaticExpansionLimit: 20)
    #expect(pending.collapsedFileIDs.isEmpty)
    synchronizeReviewFileExpansion(in: &pending, fileIDs: fileIDs, automaticExpansionLimit: 1)
    #expect(pending.collapsedFileIDs.isEmpty)

    var largeReview = ReviewState()
    synchronizeReviewFileExpansion(in: &largeReview, fileIDs: fileIDs, automaticExpansionLimit: 1)
    #expect(largeReview.collapsedFileIDs == fileIDs)
}

@Test @MainActor func repositoryCollapseRulesAreIndependentAndPersisted() throws {
    let suite = "AgentGitTests.CommitCollapse.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let firstProject = "/repos/first/shared-name"
    let secondProject = "/repos/second/shared-name"
    let settings = CommitFileCollapseSettings(defaults: defaults)
    settings.setText("*.lock", for: firstProject)
    settings.setText("**/generated/**", for: secondProject)
    #expect(settings.rules(for: firstProject).matches("deps/package.lock"))
    #expect(!settings.rules(for: secondProject).matches("deps/package.lock"))
    #expect(!settings.rules(for: firstProject).matches("generated/Model.swift"))
    #expect(settings.rules(for: secondProject).matches("generated/Model.swift"))
    #expect(settings.text(for: "/repos/third").isEmpty)

    let restored = CommitFileCollapseSettings(defaults: defaults)
    #expect(restored.text(for: firstProject) == "*.lock")
    #expect(restored.text(for: secondProject) == "**/generated/**")
    restored.setText("", for: firstProject)
    #expect(restored.text(for: firstProject).isEmpty)
    #expect(restored.text(for: secondProject) == "**/generated/**")

    restored.moveRules(from: secondProject, to: "/repos/canonical")
    let normalized = CommitFileCollapseSettings(defaults: defaults)
    #expect(normalized.text(for: secondProject).isEmpty)
    #expect(normalized.rules(for: "/repos/canonical").matches("generated/Model.swift"))

    defaults.set("*.pb.swift", forKey: "agentgit.commit-file-collapse-rules")
    let migrated = CommitFileCollapseSettings(defaults: defaults, legacyProjectID: firstProject)
    #expect(migrated.rules(for: firstProject).matches("Model.pb.swift"))
    #expect(migrated.text(for: secondProject).isEmpty)
    #expect(defaults.object(forKey: "agentgit.commit-file-collapse-rules") == nil)
}
