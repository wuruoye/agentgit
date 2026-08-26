# AgentGit

状态：MVP 开发中  
产品名：`AgentGit` 仅作开发代号；正式命名在 MVP 可用后决定。

AgentGit 首先是一款现代、原生、worktree-first 的 Git 客户端。它面向同时使用
多个 worktree 的开发方式，把代码审阅体验和本地性能放在首位。

Agent 会话关联和 MCP 是增强能力，不是产品主架构，也不阻塞 Git 客户端交付。

## 本地运行

```bash
swift test
scripts/build-app.sh debug
open .build/debug/AgentGit.app
```

发布配置使用 `scripts/build-app.sh release`，产物位于
`.build/release/AgentGit.app`。这两个构建都会产出完整的 macOS App bundle，
包含版本、开发者工具分类、多尺寸 `.icns` 图标和代码签名。图标母版位于
`Support/Assets/AgentGitAppIcon.png`。

本地默认使用开发证书签名；需要改用其它证书时设置
`AGENTGIT_SIGNING_IDENTITY`。

## 产品主路径

```text
添加项目
  -> 自动发现该仓库的全部 worktree
  -> 按最近有效活动排序
  -> 查看工作区状态和改动规模
  -> 进入高质量 Diff 审阅
  -> 查看常规 Git 历史
```

传统 Git 客户端通常以“当前 checkout”或 branch 为中心。AgentGit 以 project 下的
全部 worktree 为一级对象，让并行开发状态在一个窗口中可见。

## 产品原则

- **Git App 优先**：没有配置任何 Agent 时，仍是一款完整、有价值的 Git 客户端。
- **Review 优先**：Diff 是主工作区，不是附属弹窗。
- **Worktree 优先**：同一 Git common dir 下的 worktree 自动归为一个项目。
- **原生性能**：macOS 首版采用 SwiftUI + AppKit；大列表和大 Diff 必须虚拟化。
- **Read-first**：先把 status、diff、log 和 review 做好，再增加 Git 写操作。
- **事实来自 Git**：不从目录命名或残留配置猜 branch、worktree 和改动状态。

## M1：可运行的 Git 客户端纵向切片

M1 完成以下链路：

1. 用户添加若干本地 Git 项目；
2. App 执行 `git worktree list --porcelain -z` 自动发现全部 worktree；
3. 每个 worktree 显示 branch、HEAD、dirty 文件数、增删行数和上游 ahead/behind；
4. worktree 按最近有效活动时间降序排列；
5. 选择 worktree 后展示 changed-file 导航、unified diff 和提交历史；
6. 项目列表在下次启动时恢复；
7. Git 命令失败时在对应项目或 worktree 上显示明确错误，不让整个窗口失效。

M1 不包含 MCP、常驻 daemon、Agent hook、commit/push、reset 或 worktree
创建删除。Git 写操作仅支持 Working / Staged 中的 Stage、Unstage 和
Discard，粒度为文件、hunk 或选中行。

## 最近活动时间

排序不直接采用目录 mtime。构建产物和依赖安装会制造大量与 review 无关的文件
事件。

```text
last_activity_at = max(
  HEAD / reflog 的最近变化,
  index 的最近变化,
  Git status 中 changed / untracked 文件的最近 mtime
)
```

后续使用 FSEvents 触发增量刷新，但只有 Git-visible 状态实际变化时才更新活动
时间。

## Review 模型

最终 Review 工作区需要支持三种范围：

- **Working**：unstaged changes；
- **Staged**：index vs `HEAD`；
- **Branch**：merge-base(base, `HEAD`) 到当前 worktree 的完整变化，包含已提交与
  未提交内容。

M1 实现 Working + Staged 以及 History：提交列表（作者、日期、短 hash、
ref 徽标、merge 标记）与提交内文件级 diff，merge commit 按 first-parent
展开。Review 使用连续文件流，支持 split / unified、单文件 focus、分组折叠、
吸顶文件头、行内差异和轻量语法高亮。Diff 正文使用 AppKit `NSTableView`
复用可见行，数万行变更不会交给 SwiftUI 为每行维护布局和无障碍节点。
后续补充：

- hunk 键盘导航；
- reviewed 水位绑定确定的 diff snapshot；
- 更完整的 rename 呈现与 image diff；
- 大文件及超大变更的增量解析。

## Git 集成边界

首版直接调用系统 Git，使用稳定、机器可解析的输出：

```text
git worktree list --porcelain -z
git status --porcelain=v2 -z --branch
git diff --no-ext-diff --no-color
git diff --cached --no-ext-diff --no-color
git log -z --format=<unit-separated>
git show --format= --name-status -z --diff-merges=first-parent
```

Git 写操作限定为 Stage、Unstage 和 Discard 文件 / hunk / 行；不提供
commit、push、reset 或 worktree 创建删除。

暂不引入 libgit2。系统 Git 对 worktree、attributes、diff driver、LFS 和用户已有
配置的兼容性更接近真实命令行行为；性能问题先通过并发调度、缓存和增量刷新
解决。

## 工程结构

```text
AgentGitCore       Git 命令、解析、领域模型、项目持久化
AgentGitApp        SwiftUI App 外壳与 AppKit 高性能视图
AgentGitCoreTests  porcelain / diff parser 与真实临时仓库测试
AgentGitAppTests   AppKit Review 布局、交互与离屏快照测试
```

Git 命令异步执行，进程等待不阻塞并发线程池；UI 不直接创建 `Process`。所有路径
以绝对路径进入 core，命令参数使用 argv，不拼 shell 字符串。status 使用
`--no-optional-locks`，避免 App 自己的刷新写 index、干扰活动时间排序。

## 后续 Agent 增强

Git 客户端主路径稳定后，再增加：

1. worktree 上显示当前关联的 Agent 会话；
2. 点击 Agent 徽标精确打开对应会话；
3. App 的本地服务接受 Agent 对 worktree 的 add/remove presence；
4. 同一 worktree 可登记多个 Agent；
5. 存在 active Agent 时，未来 Git 写操作显示 busy guard。

届时会话身份和跳转统一通过 `agent-adapter`，App 不解析 provider transcript、环境
变量或 deep link。MCP 只承担 presence 注册，不扩展成第二套 Git API。

只有当 UI 关闭时仍需接受 presence，才引入轻量 LaunchAgent daemon；它属于该
增强功能，不进入 M1 的 Git 客户端进程模型。

## M1 验收

- 能添加至少三个项目并在重启后恢复；
- 一个项目的主 checkout 和多个 linked worktree 自动归组；
- worktree 排序能随真实 Git-visible 修改更新；
- staged、unstaged、untracked 状态计数正确；
- 工作区 Diff 与命令行 Git 输出一致；
- 单个失效路径或损坏仓库不会阻塞其它项目；
- 空项目、大量 worktree 和大 Diff 都不会阻塞主线程；
- `swift test` 与 `swift build` 通过。
