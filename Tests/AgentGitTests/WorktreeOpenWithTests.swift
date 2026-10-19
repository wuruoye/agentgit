@testable import AgentGitApp
import Foundation
import Testing

@Test func openWithFolderNormalization() throws {
    let cases: [(String, String)] = [
        ("", ""),
        ("  \n", ""),
        (".", ""),
        ("./", ""),
        ("MMFlutter/CrossPlatform", "MMFlutter/CrossPlatform"),
        (" MMFlutter//CrossPlatform/ ", "MMFlutter/CrossPlatform"),
        ("./MMFlutter/./CrossPlatform/.", "MMFlutter/CrossPlatform"),
        ("目录/子 工程", "目录/子 工程"),
        ("a..b/.hidden", "a..b/.hidden")
    ]
    for (input, expected) in cases {
        #expect(try WorktreeOpenWithPath.normalize(input) == expected, "\(input)")
    }

    let rejected: [(String, WorktreeOpenWithError)] = [
        ("/Users/me/repo", .absolutePath("/Users/me/repo")),
        ("~/repo", .absolutePath("~/repo")),
        ("..", .parentReference("..")),
        ("../other", .parentReference("../other")),
        ("Sources/../..", .parentReference("Sources/../..")),
        ("Sources/../Tests", .parentReference("Sources/../Tests"))
    ]
    for (input, expected) in rejected {
        #expect(throws: expected) { try WorktreeOpenWithPath.normalize(input) }
    }
}

@Test func openWithFolderMustExistInsideTheWorktree() throws {
    let base = FileManager.default.temporaryDirectory
        .appending(path: "AgentGitTests.OpenWith.\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: base) }
    let root = base.appending(path: "repo")
    let outside = base.appending(path: "outside")
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: root.appending(path: "MMFlutter/CrossPlatform"), withIntermediateDirectories: true)
    try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
    try Data().write(to: root.appending(path: "README.md"))
    try fileManager.createSymbolicLink(at: root.appending(path: "flutter"), withDestinationURL: root.appending(path: "MMFlutter"))
    try fileManager.createSymbolicLink(at: root.appending(path: "escape"), withDestinationURL: outside)
    try fileManager.createSymbolicLink(atPath: root.appending(path: "MMFlutter/up").path, withDestinationPath: "../..")

    #expect(try WorktreeOpenWithPath.resolveDirectory("", in: root).path == root.path)
    #expect(
        try WorktreeOpenWithPath.resolveDirectory(" ./MMFlutter//CrossPlatform/ ", in: root).path
            == root.appending(path: "MMFlutter/CrossPlatform").path
    )
    // 指向 worktree 内部的符号链接可以用。
    #expect(
        try WorktreeOpenWithPath.resolveDirectory("flutter/CrossPlatform", in: root).path
            == root.appending(path: "flutter/CrossPlatform").path
    )

    #expect(throws: WorktreeOpenWithError.missingDirectory(
        relativePath: "MMFlutter/Missing",
        path: root.appending(path: "MMFlutter/Missing").path
    )) {
        try WorktreeOpenWithPath.resolveDirectory("MMFlutter/Missing", in: root)
    }
    #expect(throws: WorktreeOpenWithError.notDirectory(
        relativePath: "README.md",
        path: root.appending(path: "README.md").path
    )) {
        try WorktreeOpenWithPath.resolveDirectory("README.md", in: root)
    }
    #expect(throws: WorktreeOpenWithError.outsideWorktree("escape")) {
        try WorktreeOpenWithPath.resolveDirectory("escape", in: root)
    }
    #expect(throws: WorktreeOpenWithError.outsideWorktree("MMFlutter/up")) {
        try WorktreeOpenWithPath.resolveDirectory("MMFlutter/up", in: root)
    }
    #expect(throws: WorktreeOpenWithError.parentReference("../outside")) {
        try WorktreeOpenWithPath.resolveDirectory("../outside", in: root)
    }
}

@Test func openWithChosenFolderUsesTheNearestWorktree() throws {
    let base = FileManager.default.temporaryDirectory
        .appending(path: "AgentGitTests.OpenWithChoose.\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: base) }
    let main = base.appending(path: "main")
    let nested = main.appending(path: ".claude/worktrees/feature")
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: main.appending(path: "Sources/App"), withIntermediateDirectories: true)
    try fileManager.createDirectory(at: nested.appending(path: "MMFlutter"), withIntermediateDirectories: true)
    try fileManager.createDirectory(at: base.appending(path: "elsewhere"), withIntermediateDirectories: true)
    let roots = [main, nested]

    #expect(WorktreeOpenWithPath.relativePath(of: main.appending(path: "Sources/App"), inAnyOf: roots) == "Sources/App")
    #expect(WorktreeOpenWithPath.relativePath(of: nested.appending(path: "MMFlutter"), inAnyOf: roots) == "MMFlutter")
    #expect(WorktreeOpenWithPath.relativePath(of: nested, inAnyOf: roots) == "")
    #expect(WorktreeOpenWithPath.relativePath(of: base.appending(path: "elsewhere"), inAnyOf: roots) == nil)
    // 名字前缀相同的兄弟目录不算在 worktree 里。
    try fileManager.createDirectory(at: base.appending(path: "main-copy"), withIntermediateDirectories: true)
    #expect(WorktreeOpenWithPath.relativePath(of: base.appending(path: "main-copy"), inAnyOf: roots) == nil)
}

@Test func openWithApplicationAndMenuTitle() {
    let studio = URL(fileURLWithPath: "/Applications/Android Studio.app")
    let pathEntry = WorktreeOpenWithEntry(
        applicationPath: studio.path,
        bundleIdentifier: "com.google.android.studio",
        relativePath: "MMFlutter/CrossPlatform/"
    )
    // 选中的 .app 还在时直接用它，不再按 bundle id 查找。
    #expect(pathEntry.applicationURL(fileExists: { _ in true }, lookUpBundleIdentifier: { _ in nil }) == studio)
    // .app 被移走后按 bundle id 找到新位置。
    let moved = URL(fileURLWithPath: "/Users/me/Applications/Android Studio.app")
    #expect(pathEntry.applicationURL(
        fileExists: { _ in false },
        lookUpBundleIdentifier: { $0 == "com.google.android.studio" ? moved : nil }
    ) == moved)
    #expect(WorktreeOpenWithEntry().applicationURL(fileExists: { _ in true }, lookUpBundleIdentifier: { _ in moved }) == nil)

    #expect(pathEntry.applicationName(for: nil) == "Android Studio")
    #expect(pathEntry.menuTitle(applicationURL: nil) == "Open MMFlutter/CrossPlatform with Android Studio")
    #expect(WorktreeOpenWithEntry(bundleIdentifier: "com.example.Tool").menuTitle(applicationURL: nil)
        == "Open with com.example.Tool")
    var named = pathEntry
    named.name = "  Flutter Studio "
    #expect(named.menuTitle(applicationURL: nil) == "Open with Flutter Studio")
}

@Test func openWithEntriesEncodeAndDecode() throws {
    let entry = WorktreeOpenWithEntry(
        name: "Flutter",
        applicationPath: "/Applications/Android Studio.app",
        bundleIdentifier: "com.google.android.studio",
        relativePath: "MMFlutter/CrossPlatform"
    )
    let stored = ["/repos/wechat": [entry, WorktreeOpenWithEntry(bundleIdentifier: "com.microsoft.VSCode")]]
    let data = try #require(WorktreeOpenWithSettings.encode(stored))
    #expect(WorktreeOpenWithSettings.decode(data) == stored)

    // 缺字段时补默认值，旧配置也能读。
    let partial = Data(#"{"/repos/a":[{"bundleIdentifier":"com.example.Tool"}]}"#.utf8)
    let decoded = try #require(WorktreeOpenWithSettings.decode(partial)["/repos/a"]?.first)
    #expect(decoded.bundleIdentifier == "com.example.Tool")
    #expect(decoded.name.isEmpty && decoded.applicationPath.isEmpty && decoded.relativePath.isEmpty)

    #expect(WorktreeOpenWithSettings.decode(Data("not json".utf8)).isEmpty)
    #expect(WorktreeOpenWithSettings.decode(Data(#"{"/repos/a":[{"name":3}]}"#.utf8)).isEmpty)
}

@Test @MainActor func openWithEntriesArePersistedPerRepository() throws {
    let suite = "AgentGitTests.OpenWith.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let firstProject = "/repos/first/shared-name"
    let secondProject = "/repos/second/shared-name"
    let settings = WorktreeOpenWithSettings(defaults: defaults)
    var studio = WorktreeOpenWithEntry(bundleIdentifier: "com.google.android.studio", relativePath: "MMFlutter")
    let code = WorktreeOpenWithEntry(bundleIdentifier: "com.microsoft.VSCode")
    settings.append(studio, for: firstProject)
    settings.append(code, for: firstProject)
    settings.append(code, for: secondProject)
    studio.relativePath = "MMFlutter/CrossPlatform"
    settings.update(studio, for: firstProject)

    let restored = WorktreeOpenWithSettings(defaults: defaults)
    #expect(restored.entries(for: firstProject) == [studio, code])
    #expect(restored.entries(for: secondProject) == [code])
    #expect(restored.entries(for: "/repos/third").isEmpty)

    restored.remove(id: code.id, for: firstProject)
    restored.moveEntries(from: secondProject, to: "/repos/canonical")
    let normalized = WorktreeOpenWithSettings(defaults: defaults)
    #expect(normalized.entries(for: firstProject) == [studio])
    #expect(normalized.entries(for: secondProject).isEmpty)
    #expect(normalized.entries(for: "/repos/canonical") == [code])
}
