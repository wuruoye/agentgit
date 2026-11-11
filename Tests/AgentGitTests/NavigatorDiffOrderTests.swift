@testable import AgentGitApp
import AgentGitCore
import Testing

/// 右侧 diff 的文件顺序要和左侧文件树从上到下的顺序一致。
@Test func diffFileOrderMatchesNavigatorTreeOrder() {
    let paths = [
        "pkg/standalone/lib/web/ting_web_host_registrar_impl.dart",
        "pkg/standalone/lib/web/ting_web_host_registrar.dart",
        "pkg/standalone/lib/web/ting_web_host_registrar_stub.dart",
        "pkg/standalone/lib/web/ting_web_player.dart",
        "pkg/standalone/lib/main.dart",
        "pkg/standalone/lib/login/login.dart",
        "pkg/standalone/lib/login/Web_qr_image_web.dart",
        "pkg/standalone/lib/emoji/standalone_emoji_bootstrap.dart",
        "pkg/standalone/lib/page/setting_page.dart",
        "pkg/standalone/pubspec.yaml",
        "pkg/standalone/.gitignore",
        "pkg/standalone/scripts/build_web.sh",
        "pkg/standalone/scripts/lib/export.py",
        "README.md",
        "Zeta/a.txt"
    ]
    let items = paths.map { path in
        let change = GitFileChange(path: path, originalPath: nil, indexStatus: ".", worktreeStatus: "M", kind: .ordinary)
        return IntegratedFileItem(id: .pending(scope: .working, changeID: change.id), change: change, scope: .working)
    }
    let nodes = navigatorTreeNodes(items: items, namespace: "working")
    var allFolderIDs = Set<String>()
    func collect(_ nodes: [NavigatorTreeNode]) {
        for node in nodes {
            if case let .folder(id, _, _, children) = node {
                allFolderIDs.insert(id)
                collect(children)
            }
        }
    }
    collect(nodes)
    let navigatorOrder = flattenedNavigatorTreeRows(nodes: nodes, expandedFolderIDs: allFolderIDs)
        .compactMap { $0.fileItem?.change.path }
    let diffOrder = sortedInNavigatorOrder(items, path: \.change.path).map(\.change.path)

    #expect(navigatorOrder.count == paths.count)
    #expect(diffOrder == navigatorOrder)
    // 同一层文件夹在前；`.` 比 `_` 小，registrar.dart 排在 registrar_impl.dart 前面。
    #expect(diffOrder.firstIndex(of: "pkg/standalone/lib/web/ting_web_player.dart")!
        < diffOrder.firstIndex(of: "pkg/standalone/lib/main.dart")!)
    #expect(diffOrder.firstIndex(of: "pkg/standalone/lib/web/ting_web_host_registrar.dart")!
        < diffOrder.firstIndex(of: "pkg/standalone/lib/web/ting_web_host_registrar_impl.dart")!)
    #expect(diffOrder.last == "README.md")
}

/// 缓存里存的可能是旧排序的文件列表，生成右侧文件时也要按左侧树的顺序。
@Test @MainActor func contextItemsFollowNavigatorOrderEvenFromStaleCache() {
    let stalePaths = [
        "lib/login/login.dart",
        "lib/main.dart",
        "lib/web/ting_web_host_registrar_impl.dart",
        "lib/web/ting_web_host_registrar.dart",
        "lib/emoji/bootstrap.dart"
    ]
    let changes = stalePaths.map {
        GitFileChange(path: $0, originalPath: nil, indexStatus: "M", worktreeStatus: ".", kind: .ordinary)
    }
    let entry = ContextFileItemsCache().entry(contextID: "commit:abc", changes: changes)
    #expect(entry.items.map(\.change.path) == [
        "lib/emoji/bootstrap.dart",
        "lib/login/login.dart",
        "lib/web/ting_web_host_registrar.dart",
        "lib/web/ting_web_host_registrar_impl.dart",
        "lib/main.dart"
    ])
    #expect(entry.fileIDs == entry.items.map(\.id))
}

@Test func collapsedFoldersRevealThroughAncestorFolderIDs() {
    let paths = [
        "pkg/standalone/lib/web/impl.dart",
        "pkg/standalone/lib/web/stub.dart",
        "pkg/standalone/lib/main.dart",
        "pkg/standalone/scripts/build.sh",
        "README.md"
    ]
    let items = paths.map { path in
        let change = GitFileChange(path: path, originalPath: nil, indexStatus: ".", worktreeStatus: "M", kind: .ordinary)
        return IntegratedFileItem(id: .pending(scope: .working, changeID: change.id), change: change, scope: .working)
    }
    let target = items[0]
    let nodes = navigatorTreeNodes(items: items, namespace: "working")
    let allFolderIDs = navigatorFolderIDs(in: nodes)
    func rows(collapsed: Set<String>) -> [NavigatorTreeRow] {
        flattenedNavigatorTreeRows(nodes: nodes, expandedFolderIDs: allFolderIDs.subtracting(collapsed))
    }
    let ancestors = navigatorAncestorFolderIDs(ofFilePath: target.change.path, namespace: "working")
    // 文件夹行的 id（含合并成一行的链）都能在文件的祖先 id 里找到。
    let targetFolderRows = rows(collapsed: []).compactMap { row -> String? in
        guard case let .folder(id, _, path, _) = row.content,
              target.change.path.hasPrefix(path + "/") else { return nil }
        return id
    }
    #expect(!targetFolderRows.isEmpty)
    #expect(Set(targetFolderRows).isSubset(of: ancestors))

    // 全部展开时选中文件本身。
    #expect(navigatorRowSelection(forFilePath: target.change.path, fileID: target.id.stackID, in: rows(collapsed: []))
        == .file(target.id.stackID))

    // 收起最外层文件夹：选中这个文件夹行，它是文件当前唯一能看到的位置。
    let outermost = targetFolderRows[0]
    #expect(navigatorRowSelection(forFilePath: target.change.path, fileID: target.id.stackID, in: rows(collapsed: [outermost]))
        == .folder(outermost))

    // 收起里层文件夹：选中最深的那个还能看到的文件夹。
    let innermost = targetFolderRows[targetFolderRows.count - 1]
    #expect(navigatorRowSelection(forFilePath: target.change.path, fileID: target.id.stackID, in: rows(collapsed: [innermost]))
        == .folder(innermost))

    // 去掉祖先 id 之后文件重新可见；其他分支的收起状态不受影响。
    let unrelated = rows(collapsed: []).compactMap { row -> String? in
        guard case let .folder(id, _, path, _) = row.content, path.hasSuffix("scripts") else { return nil }
        return id
    }
    let collapsed = Set([outermost, innermost] + unrelated)
    let remaining = collapsed.subtracting(ancestors)
    #expect(remaining == Set(unrelated))
    #expect(navigatorRowSelection(forFilePath: target.change.path, fileID: target.id.stackID, in: rows(collapsed: remaining))
        == .file(target.id.stackID))
}

/// 左侧选中文件夹时右侧滚到的文件，就是右侧这个文件夹下排在最前面的文件。
@Test func folderFirstFileMatchesDiffOrder() {
    let paths = [
        "pkg/standalone/lib/web/stub.dart",
        "pkg/standalone/lib/main.dart",
        "pkg/standalone/lib/web/impl.dart",
        "pkg/standalone/lib/emoji/a.dart",
        "pkg/standalone/scripts/build.sh"
    ]
    let items = paths.map { path in
        let change = GitFileChange(path: path, originalPath: nil, indexStatus: ".", worktreeStatus: "M", kind: .ordinary)
        return IntegratedFileItem(id: .pending(scope: .working, changeID: change.id), change: change, scope: .working)
    }
    let nodes = navigatorTreeNodes(items: items, namespace: "working")
    let diffOrder = sortedInNavigatorOrder(items, path: \.change.path)
    let rows = flattenedNavigatorTreeRows(nodes: nodes, expandedFolderIDs: navigatorFolderIDs(in: nodes))
    for row in rows {
        guard case let .folder(id, _, path, _) = row.content else { continue }
        let expected = diffOrder.first { $0.change.path.hasPrefix(path + "/") }?.id.stackID
        #expect(firstNavigatorFileID(in: id, nodes: nodes) == expected, "folder \(path)")
    }
}
