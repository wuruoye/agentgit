@testable import AgentGitApp
import AgentGitCore
import Testing

private func navigatorItem(_ path: String) -> IntegratedFileItem {
    let change = GitFileChange(
        path: path, originalPath: nil, indexStatus: ".", worktreeStatus: "M", kind: .ordinary
    )
    return IntegratedFileItem(
        id: .pending(scope: .working, changeID: change.id),
        change: change,
        scope: .working
    )
}

/// 每行写成 `深度 标题 @ 完整路径`，文件行只写深度和路径。
private func describe(_ rows: [NavigatorTreeRow]) -> [String] {
    rows.map { row in
        switch row.content {
        case let .folder(_, name, path, fileCount):
            "\(row.depth) \(name) @ \(path) (\(fileCount))"
        case let .file(item):
            "\(row.depth) \(item.change.path)"
        }
    }
}

private let compactionItems = [
    "MMFlutter/CrossPlatform/packages/ting/standalone/lib/emoji/a.dart",
    "MMFlutter/CrossPlatform/packages/ting/standalone/lib/emoji/b.dart",
    "MMFlutter/CrossPlatform/packages/ting/standalone/lib/web/c.dart",
    "tools/predeploy/gen.py",
    "tools/rpc-proxy/music_pb/x_pb2.py",
    "README.md"
].map(navigatorItem)

@Test func navigatorMergesSingleChildFolderChains() {
    let nodes = navigatorTreeNodes(items: compactionItems, namespace: "working")
    let rows = flattenedNavigatorTreeRows(
        nodes: nodes,
        expandedFolderIDs: navigatorFolderIDs(in: nodes)
    )
    #expect(describe(rows) == [
        "0 MMFlutter/CrossPlatform/packages/ting/standalone/lib @ MMFlutter/CrossPlatform/packages/ting/standalone/lib (3)",
        "1 emoji @ MMFlutter/CrossPlatform/packages/ting/standalone/lib/emoji (2)",
        "2 MMFlutter/CrossPlatform/packages/ting/standalone/lib/emoji/a.dart",
        "2 MMFlutter/CrossPlatform/packages/ting/standalone/lib/emoji/b.dart",
        "1 web @ MMFlutter/CrossPlatform/packages/ting/standalone/lib/web (1)",
        "2 MMFlutter/CrossPlatform/packages/ting/standalone/lib/web/c.dart",
        "0 tools @ tools (2)",
        "1 predeploy @ tools/predeploy (1)",
        "2 tools/predeploy/gen.py",
        "1 rpc-proxy/music_pb @ tools/rpc-proxy/music_pb (1)",
        "2 tools/rpc-proxy/music_pb/x_pb2.py",
        "0 README.md"
    ])
    // 合并后的行用最深一层文件夹的 id，中间层不再单独出现。
    let merged = "navigator-folder:working:tools/rpc-proxy/music_pb"
    #expect(rows.compactMap(\.folderID).contains(merged))
    #expect(!navigatorFolderIDs(in: nodes).contains("navigator-folder:working:tools/rpc-proxy"))
    #expect(
        firstNavigatorFileID(in: merged, nodes: nodes)
            == compactionItems[4].id.stackID
    )
}

@Test func navigatorMergesAgainAfterFiltering() {
    let nodes = filteredNavigatorTreeNodes(
        navigatorTreeNodes(items: compactionItems, namespace: "working"),
        query: "music"
    )
    let rows = flattenedNavigatorTreeRows(
        nodes: nodes,
        expandedFolderIDs: navigatorFolderIDs(in: nodes)
    )
    #expect(describe(rows) == [
        "0 tools/rpc-proxy/music_pb @ tools/rpc-proxy/music_pb (1)",
        "1 tools/rpc-proxy/music_pb/x_pb2.py"
    ])
    #expect(rows.first?.folderID == "navigator-folder:working:tools/rpc-proxy/music_pb")
}

@Test @MainActor func navigatorCollapsesMergedFolderRow() {
    let cache = NavigatorTreeCache()
    let merged = "navigator-folder:working:MMFlutter/CrossPlatform/packages/ting/standalone/lib"
    let rows = cache.rows(
        items: compactionItems,
        namespace: "working",
        query: "",
        collapsedFolderIDs: [merged, "navigator-folder:working:tools"]
    )
    #expect(describe(rows.rows) == [
        "0 MMFlutter/CrossPlatform/packages/ting/standalone/lib @ MMFlutter/CrossPlatform/packages/ting/standalone/lib (3)",
        "0 tools @ tools (2)",
        "0 README.md"
    ])
    #expect(!rows.expandedFolderIDs.contains(merged))
}
