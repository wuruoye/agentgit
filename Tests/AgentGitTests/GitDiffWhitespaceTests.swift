import AgentGitCore
import Foundation
import Testing

/// 给 Stack 外面包一层 Padding，整块多缩进两格。原 diff 里凑巧相同的短行把改动切成好几块，
/// 新旧对应行落在不同块里；忽略空白后应与 `git diff -w` 一样只剩真正新增的三行。
@Test func ignoringWhitespaceMatchesGitForReindentedBlock() throws {
    let diff = try whitespaceFixtureDiff(reindentedBlockWholeFilePatch)

    let ignored = GitDiffWhitespaceFilter.ignoringWhitespace(
        diff, context: .lines(3), recomputesSectionHeadings: true
    )

    #expect(renderedHunks(ignored) == reindentedBlockIgnoringWhitespace.components(separatedBy: "\n"))
}

/// 只有 3 行上下文时，改动行仍与 git 一致；git 把新增的 `),` 放在最后一个，它后面的上下文超出了原 hunk。
@Test func ignoringWhitespaceRealignsReindentedBlockFromCompactDiff() throws {
    let compact = GitDiffContextTrimmer.trimming(
        try whitespaceFixtureDiff(reindentedBlockWholeFilePatch), to: .lines(3), recomputesSectionHeadings: true
    )
    #expect(compact.hunks.count == 1)

    let ignored = GitDiffWhitespaceFilter.ignoringWhitespace(
        compact, context: .lines(3), recomputesSectionHeadings: true
    )

    let changedLines = ignored.hunks.flatMap(\.lines).filter { $0.kind == .addition || $0.kind == .deletion }
    #expect(changedLines.map(\.kind) == [.addition, .addition, .addition])
    #expect(changedLines.map(\.newLineNumber) == [9, 10, 67])
    #expect(changedLines.map(\.content) == ["          child: Padding(", "            padding: insets,", "        ),"])
}

/// 给了整文件 diff 就从它重算，3 行上下文的结果也与 git -w 逐行一致；
/// 改动行沿用界面上 diff 的行 id，不重算标题时沿用对应 hunk 的标题。
@Test(arguments: [true, false])
func ignoringWhitespaceWithWholeFileSourceMatchesGit(recomputesSectionHeadings: Bool) throws {
    let wholeFile = try whitespaceFixtureDiff(reindentedBlockWholeFilePatch)
    let compact = GitDiffContextTrimmer.trimming(wholeFile, to: .lines(3), recomputesSectionHeadings: true)
    #expect(GitDiffWhitespaceFilter.isWholeFileSource(wholeFile, of: compact))

    let ignored = GitDiffWhitespaceFilter.ignoringWhitespace(
        compact, context: .lines(3), recomputesSectionHeadings: recomputesSectionHeadings,
        wholeFileSource: wholeFile
    )

    #expect(renderedHunks(ignored) == reindentedBlockIgnoringWhitespace.components(separatedBy: "\n"))
    // 第 67 行的 `),` 在原 diff 里是上下文，git -w 才把它算作新增，补丁里没有它，只能另起 id。
    let compactLines = compact.hunks.flatMap(\.lines)
    let compactAdditionIDs = Dictionary(uniqueKeysWithValues: compactLines.compactMap { line in
        line.kind == .addition ? line.newLineNumber.map { ($0, line.id) } : nil
    })
    let additions = ignored.hunks.flatMap(\.lines).filter { $0.kind == .addition }
    #expect(additions.map(\.newLineNumber) == [9, 10, 67])
    #expect(additions[0].id == compactAdditionIDs[9])
    #expect(additions[1].id == compactAdditionIDs[10])
    #expect(!compactLines.map(\.id).contains(additions[2].id))
    let ids = ignored.hunks.flatMap(\.lines).map(\.id)
    #expect(Set(ids).count == ids.count)
}

/// 内容对不上的整文件 diff 不用，退回只看 hunk 内容。
@Test func ignoringWhitespaceIgnoresMismatchedWholeFileSource() throws {
    let wholeFile = try whitespaceFixtureDiff(reindentedBlockWholeFilePatch)
    let compact = GitDiffContextTrimmer.trimming(wholeFile, to: .lines(3), recomputesSectionHeadings: true)
    let other = try whitespaceFixtureDiff(missingFinalNewlinePatch)

    #expect(!GitDiffWhitespaceFilter.isWholeFileSource(compact, of: compact))
    #expect(!GitDiffWhitespaceFilter.isWholeFileSource(other, of: compact))
    #expect(
        GitDiffWhitespaceFilter.ignoringWhitespace(compact, context: .lines(3), wholeFileSource: other)
            == GitDiffWhitespaceFilter.ignoringWhitespace(compact, context: .lines(3))
    )
}

/// git -w 把缺少的行尾换行也当空白：只改缩进和末尾换行的行成为上下文，标记跟随新侧。
@Test func ignoringWhitespaceTreatsMissingFinalNewlineAsWhitespace() throws {
    let diff = try whitespaceFixtureDiff(missingFinalNewlinePatch)

    let ignored = GitDiffWhitespaceFilter.ignoringWhitespace(
        diff, context: .lines(3), recomputesSectionHeadings: true
    )

    #expect(renderedHunks(ignored) == missingFinalNewlineIgnoringWhitespace.components(separatedBy: "\n"))
}

/// hunk 标题取前 80 字节，截在多字节字符中间时 git 丢掉这半个字符，截断前的空格保留（git 2.54 实测）。
@Test func recomputedHeadingsDropPartialMultibyteCharacterLikeGit() throws {
    func a(_ count: Int) -> String { String(repeating: "a", count: count) }
    let oldLines = [a(78) + "中文 tail"] + (0..<10).map { " x\($0)" }
        + [a(77) + " 中 tail"] + (0..<10).map { " y\($0)" }
        + [a(79) + "中"] + (0..<10).map { " z\($0)" }
    let newLines = oldLines.map { [" x8": " X8", " y8": " Y8", " z8": " Z8"][$0] ?? $0 }
    var patch = ["@@ -1,\(oldLines.count) +1,\(newLines.count) @@"]
    for (old, new) in zip(oldLines, newLines) {
        patch += old == new ? [" " + old] : ["-" + old, "+" + new]
    }

    let trimmed = GitDiffContextTrimmer.trimming(
        try whitespaceFixtureDiff(patch.joined(separator: "\n")), to: .lines(3), recomputesSectionHeadings: true
    )

    #expect(trimmed.hunks.map(\.header) == [
        "@@ -7,7 +7,7 @@ " + a(78),
        "@@ -18,7 +18,7 @@ " + a(77) + " ",
        "@@ -29,5 +29,5 @@ " + a(79)
    ])
}

/// 新建或删除整个文件时 hunk 只有一侧，忽略空白后原样保留。
@Test(arguments: ["@@ -0,0 +1,2 @@\n+  one\n+two", "@@ -1,2 +0,0 @@\n-  one\n-two"])
func ignoringWhitespaceKeepsOneSidedHunk(patch: String) throws {
    let diff = try whitespaceFixtureDiff(patch)

    for source in [nil, diff] {
        let ignored = GitDiffWhitespaceFilter.ignoringWhitespace(diff, context: .lines(3), wholeFileSource: source)
        #expect(renderedHunks(ignored) == renderedHunks(diff))
    }
}

/// 随机组合只差空白的行、空行和缺行尾换行，各种上下文和整文件来源下都不崩溃，行号连续、计数对得上。
@Test func ignoringWhitespaceHandlesRandomHunks() throws {
    let variants = ["}", "  }", "\t}", "a b", "a  b", "", "  ", "x", " x", "y"]
    var seed: UInt64 = 0x5EED
    func next(_ bound: Int) -> Int {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((seed >> 33) % UInt64(bound))
    }

    for _ in 0..<1_500 {
        var oldCount = 0
        var newCount = 0
        var body: [String] = []
        for _ in 0..<(1 + next(30)) {
            let content = variants[next(variants.count)]
            switch next(3) {
            case 0: body.append(" " + content); oldCount += 1; newCount += 1
            case 1: body.append("-" + content); oldCount += 1
            default: body.append("+" + content); newCount += 1
            }
        }
        if next(4) == 0 {
            body.append("\\ No newline at end of file")
        }
        let header = "@@ -\(oldCount == 0 ? 0 : 1),\(oldCount) +\(newCount == 0 ? 0 : 1),\(newCount) @@"
        let wholeFile = try whitespaceFixtureDiff(([header] + body).joined(separator: "\n"))

        for context in [GitDiffContext.lines(0), .lines(3), .wholeFile] {
            let compact = GitDiffContextTrimmer.trimming(wholeFile, to: context, recomputesSectionHeadings: true)
            for source in [nil, wholeFile] {
                let ignored = GitDiffWhitespaceFilter.ignoringWhitespace(
                    compact, context: context, recomputesSectionHeadings: true, wholeFileSource: source
                )
                let lines = ignored.hunks.flatMap(\.lines)
                #expect(Set(lines.map(\.id)).count == lines.count)
                for hunk in ignored.hunks {
                    #expect(hunk.lines.count { $0.oldLineNumber != nil } == hunk.oldCount)
                    #expect(hunk.lines.count { $0.newLineNumber != nil } == hunk.newCount)
                }
                if context == .wholeFile, source != nil, !ignored.hunks.isEmpty {
                    #expect(lines.compactMap(\.oldLineNumber) == Array(0..<oldCount).map { $0 + 1 })
                    #expect(lines.compactMap(\.newLineNumber) == Array(0..<newCount).map { $0 + 1 })
                }
            }
        }
    }
}

private func whitespaceFixtureDiff(_ patch: String) throws -> GitFileDiff {
    let change = GitFileChange(
        path: "preview.dart", originalPath: nil, indexStatus: "M", worktreeStatus: ".", kind: .ordinary
    )
    return try UnifiedDiffParser.parse(Data(patch.utf8), change: change, scope: .staged)
}

private func renderedHunks(_ diff: GitFileDiff) -> [String] {
    diff.hunks.flatMap { hunk in
        [hunk.header] + hunk.lines.map { line in
            switch line.kind {
            case .context: " " + line.content
            case .addition: "+" + line.content
            case .deletion: "-" + line.content
            case .metadata: line.content
            }
        }
    }
}

// 以下四段都是 git 2.54 的原样输出。

/// `git diff -U1000000`
private let reindentedBlockWholeFilePatch = #"""
@@ -1,68 +1,71 @@
 class PreviewCard extends StatelessWidget {
   @override
   Widget build(BuildContext context) {
     return Stack(
       children: [
         const Background(),
         Opacity(
           opacity: opacity,
-          child: Stack(
-            fit: StackFit.expand,
-            children: [
-              Positioned(
-                left: padding,
-                top: layout.coverTop,
-                width: coverSize,
-                height: coverSize,
-                child: CoverImage(
-                  key: ValueKey('cover-${item.id}'),
+          child: Padding(
+            padding: insets,
+            child: Stack(
+              fit: StackFit.expand,
+              children: [
+                Positioned(
+                  left: padding,
+                  top: layout.coverTop,
                   width: coverSize,
                   height: coverSize,
-                  item: item,
+                  child: CoverImage(
+                    key: ValueKey('cover-${item.id}'),
+                    width: coverSize,
+                    height: coverSize,
+                    item: item,
+                  ),
                 ),
-              ),
-              if (showHeader)
-                Header(
+                if (showHeader)
+                  Header(
+                    item: item,
+                    layout: layout,
+                  ),
+                Source(
                   item: item,
                   layout: layout,
                 ),
-              Source(
-                item: item,
-                layout: layout,
-              ),
-              Positioned(
-                left: padding,
-                right: padding,
-                bottom: layout.infoBottom,
-                child: Info(
-                  item: item,
-                  title: title,
-                  author: author,
+                Positioned(
+                  left: padding,
+                  right: padding,
+                  bottom: layout.infoBottom,
+                  child: Info(
+                    item: item,
+                    title: title,
+                    author: author,
+                  ),
                 ),
-              ),
-              Positioned(
-                left: padding,
-                right: padding,
-                bottom: layout.controlsBottom,
-                height: controlsHeight,
-                child: const Controls(),
-              ),
-              Positioned(
-                left: 0,
-                right: 0,
-                bottom: layout.actionsBottom,
-                child: ActionRow(
-                  item: item,
-                  onShare: () {},
-                  onLike: () {},
-                  onMore: () {},
-                  isCompact: layout.isCompact,
+                Positioned(
+                  left: padding,
+                  right: padding,
+                  bottom: layout.controlsBottom,
+                  height: controlsHeight,
+                  child: const Controls(),
+                ),
+                Positioned(
+                  left: 0,
+                  right: 0,
+                  bottom: layout.actionsBottom,
+                  child: ActionRow(
+                    item: item,
+                    onShare: () {},
+                    onLike: () {},
+                    onMore: () {},
+                    isCompact: layout.isCompact,
+                  ),
                 ),
-              ),
-            ],
+              ],
+            ),
           ),
         ),
       ],
     );
   }
 }
"""#

/// `git diff -w`
private let reindentedBlockIgnoringWhitespace = #"""
@@ -6,6 +6,8 @@ class PreviewCard extends StatelessWidget {
         const Background(),
         Opacity(
           opacity: opacity,
+          child: Padding(
+            padding: insets,
             child: Stack(
               fit: StackFit.expand,
               children: [
@@ -62,6 +64,7 @@ class PreviewCard extends StatelessWidget {
               ],
             ),
           ),
+        ),
       ],
     );
   }
"""#

/// `git diff`
private let missingFinalNewlinePatch = #"""
@@ -1,4 +1,4 @@
-let value = 1
+let value = 2
 if ready {
-run()
-}
\ No newline at end of file
+    run()
+}
"""#

/// `git diff -w`
private let missingFinalNewlineIgnoringWhitespace = #"""
@@ -1,4 +1,4 @@
-let value = 1
+let value = 2
 if ready {
     run()
 }
"""#
