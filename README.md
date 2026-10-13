# AgentGit

状态：原生 macOS 开发版本，可用于日常 worktree review。

本项目采用 [MIT License](LICENSE)。

AgentGit 首先是一款现代、原生、worktree-first 的 Git 客户端。它面向同时使用
多个 worktree 的开发方式，把代码审阅体验和本地性能放在首位。

## 工作区界面

- **多 worktree 总览**：`All Worktrees` 按项目展示紧凑列表，分支、文件数、增删行数、
  上游同步状态和活动时间按列对齐。有本地改动时仍显示同步状态；支持搜索和需要处理的
  worktree 筛选，点击行进入审阅。
- **审阅布局**：项目和分支在侧栏中选择，切换 worktree 后恢复原有 Review 状态。
  Pull / Push 在工具栏中。`History` 独立
  展开或收起提交历史；`Focus`（`⇧⌘F`）收起项目侧栏和历史、保留文件导航，退出后恢复
  原布局。右侧顶部显示比较范围和统计；文件头把文件名、目录分成两行，暂存按钮、增删
  统计和 Reviewed 按钮保持固定位置。hunk 标题显示代码范围，分组与文件头继续吸顶。
  `Display` 菜单提供带勾选状态的忽略空白选项，审阅进度、独立的全部折叠／展开与 hunk
  导航固定在差异区顶部。部分文件展开时也可直接全部折叠，Review 菜单提供相同操作。
  操作按钮使用统一的圆角、悬停、按下和禁用状态；图标采用 SF Symbols，SVG 后备图标位于
  `Sources/AgentGitApp/Resources/ReviewIcons`，随 App 打包并缓存复用。
- **快捷切换**：`⌘P` 搜索全部 worktree，使用方向键与 Return 或直接点击打开。
  `⌘+`（或 `⌘=`）和 `⌘-` 全局调整字号及对应布局，范围为 80%–150%，`⌘0` 恢复 100%；
  设置跨启动保存，窄窗口放大时自动收起项目侧栏，恢复足够空间后还原。
  `⌘F` 跟随总览或当前操作的提交、文件导航；`⌘1` / `⌘2` 聚焦对应列表，隐藏的历史会自动展开。
  侧栏保留项目拖拽、worktree 置顶、折叠、筛选和右键操作，底部提供 Settings 入口。
- **原生显示**：深浅色随系统切换。已安装 Claude 时，界面文字采用其 Anthropic Sans；
  字体仅注册在 AgentGit 进程中，缺失时使用系统字体。代码采用 13 点等宽字体和 20 点行高，Diff 继续由
  AppKit 虚拟列表绘制。窗口最小尺寸为 `1040×680`，项目侧栏和 Review 导航可以拖动调宽。

## 本地运行

运行需要 macOS 14 或更新版本，以及 Xcode Command Line Tools。编译需要 Swift 6.2 或更新版本。

```bash
scripts/build-app.sh debug
open .build/debug/AgentGit.app
```

日常使用时执行：

```bash
scripts/install-local.sh
```

脚本会构建签名 Release、结束旧的 AgentGit Debug / Release 进程、原子更新
`~/Applications/AgentGit.app`，验证安装后的签名，清理构建副本的 LaunchServices 注册，
再通过 `open -g` 从后台启动。
只安装、不启动时使用 `scripts/install-local.sh --no-launch`；需要其它安装目录时设置
`AGENTGIT_INSTALL_DIR`。

发布配置使用 `scripts/build-app.sh release`，产物位于
`.build/release/AgentGit.app`。这两个构建都会产出完整的 macOS App bundle，
包含版本、开发者工具分类、多尺寸 `.icns` 图标和代码签名。图标母版位于
`Support/Assets/AgentGitAppIcon.png`。

`scripts/package-app.sh` 会生成启用 hardened runtime 的 Release 应用、版本化 zip 和
SHA-256 校验文件，产物位于 `.build/release/`。本地开发证书产物用于受信任设备安装；
对外分发仍需 Developer ID Application 证书与 Apple notarization。

公开分发前，先把 App Store Connect 凭据保存到 Keychain，再使用 Developer ID Application
身份执行公证打包：

```bash
xcrun notarytool store-credentials agentgit-notary
AGENTGIT_SIGNING_IDENTITY='Developer ID Application: Example (TEAMID)' \
AGENTGIT_NOTARY_PROFILE='agentgit-notary' \
scripts/package-app.sh --notarize
```

公证模式会等待 Apple 返回终态，把 ticket staple 到 `.app`，重新生成最终 zip 和 SHA-256，
再验证解压后的签名、staple ticket 与 Gatekeeper。凭据只从 Keychain profile 读取。

本地默认使用不依赖证书的 ad-hoc 签名。重新构建后，macOS 可能重新请求目录访问权限。
需要让权限跨构建保留时，可设置自己的固定开发证书：

```bash
AGENTGIT_SIGNING_IDENTITY='Apple Development: Example (TEAMID)' scripts/install-local.sh
```

## 产品主路径

```text
添加项目
  -> 自动发现该仓库的全部 worktree
  -> 项目保持手动拖拽顺序
  -> 项目内部按列表展示的最近更新时间排列 worktree
  -> 每个项目显示近期 worktree，所有有修改的 worktree 始终显示
  -> 查看工作区状态和改动规模
  -> 进入高质量 Diff 审阅
  -> 查看常规 Git 历史
```

传统 Git 客户端通常以“当前 checkout”或 branch 为中心。AgentGit 以 project 下的
全部 worktree 为一级对象，让并行开发状态在一个窗口中可见。

## 产品原则

- **Git App 优先**：没有配置任何 Agent 时，仍是一款完整、有价值的 Git 客户端。
- **Review 优先**：Diff 占据主工作区，审阅体验保持最高优先级。
- **Worktree 优先**：同一 Git common dir 下的 worktree 自动归为一个项目。
- **原生性能**：macOS 首版采用 SwiftUI + AppKit；大列表和大 Diff 必须虚拟化。
- **Read-first**：先把 status、diff、log 和 review 做好，再增加 Git 写操作。
- **事实来自 Git**：不从目录命名或残留配置猜 branch、worktree 和改动状态。

持续审查与验证状态记录在 [产品缺陷与打磨清单](docs/product-polish-checklist.md)。

## M1：可运行的 Git 客户端纵向切片

M1 完成以下链路：

1. 用户添加若干本地 Git 项目；
2. App 执行 `git worktree list --porcelain -z` 自动发现全部 worktree；
   从任意 linked worktree 添加时都解析到同一主 checkout，已有重复保存项在启动时按该身份
   合并，并保留首次出现的位置；
3. 每个 worktree 显示 branch、HEAD、dirty 文件数、增删行数和上游 ahead/behind；
4. 项目支持折叠和手动拖拽排序；每个项目默认显示最多四个近期活跃 worktree，所有有修改
   或置顶的 worktree 都保留显示，不受四条上限和闲置时间影响；其余通过列表末尾控件展开；
5. 选择 worktree 后展示 changed-file 导航、unified diff 和提交历史；
6. 项目列表与最后选中的 worktree 在下次启动时恢复；
7. Git 命令失败时在对应项目或 worktree 上显示明确错误和恢复操作，不让整个窗口失效。

侧边栏可按项目名、路径、分支、worktree 路径和 HEAD 短哈希搜索；`⌘P` 打开可搜索的
worktree 切换窗口，并直接使用已恢复的缓存快照。项目顺序同时提供拖拽与
Move Up / Move Down 菜单操作。侧栏、History、Files 和 Review 的筛选没有结果时
都在原位置提供 Clear Filter。筛选、折叠和列表重建不会清除当前 Review；已经移除的
worktree ID 也不会覆盖当前有效选择。

M1 不包含 commit、reset 或 worktree 创建。Git 写操作支持 Working / Staged 中的 Stage、Unstage 和 Discard，
粒度为文件、hunk 或选中行；当前分支另外提供 fast-forward-only Pull 与 Push。

## Worktree 自动清理

Settings → Worktrees 提供自动清理开关，默认关闭。开启后默认每小时检查一次，清理闲置
至少 7 天的干净 linked worktree；可选择每 1 / 6 / 24 小时检查、闲置 3 / 7 / 14 / 30 天。
应用保持运行时在后台也会检查，退出后停止；最近检查时间跨启动保存，到期后自动补查。
设置页面显示最近一次清理的数量、已删除路径、保留原因和错误，可复制完整清理结果并在
Finder 中打开诊断日志目录。
Clean Up Now 按钮立即检查并清理符合条件的 worktree，跳过等待周期；自动清理关闭时也可
执行一次，且不会打开自动清理。手动执行同样遵守闲置天数、项目排除与全部删除保护，运行中
禁用按钮，完成后更新最近检查结果与下一次自动检查的计时。

可在 Settings → Worktrees → Excluded Projects 勾选不参与自动清理的项目，也可通过
项目右键菜单的 Exclude from Automatic Cleanup 切换。排除设置按项目保存，重启以及移除后
重新添加同一项目仍保留，覆盖该项目已有和后续新增的全部 worktree；其他项目继续使用全局
清理设置。检查开始前和删除前都会复核排除设置，已经开始执行的删除会完成。

闲置时间与列表显示的 `lastActivityAt` 使用同一计算方式，并在删除前重新读取。查看 worktree、
Agent 会话登记、目录创建时间、干净文件和忽略文件的时间均不额外阻止清理。Git 忽略的文件
和构建产物会随符合条件的 worktree 一起删除。

主 checkout、置顶、当前选中、锁定以及正在执行 Git 操作的 worktree 会保留。主 worktree
是强制保护项，自动和手动清理均不可删除，项目配置不会解除该保护。删除前重新检查 Git
成员、状态、HEAD 与列表活动时间；本地改动按 AgentGit Review 使用的 Git 状态判定，
包含 staged / unstaged / untracked 改动或无法确认状态的目录都跳过。

普通 worktree 使用不带 `--force` 的 `git worktree remove`；包含已初始化 submodule 时，在
重新确认 Git 状态为空及目录保护条件后使用一次 `--force`。清理保留主仓库本地分支（包括尚未推送的提交）；
detached HEAD 仅在提交仍被本地分支、远端跟踪分支或标签引用时允许清理。清理完成后立即
更新列表与持久化快照。该功能会实际删除符合条件的目录，启用开关后无需逐项确认。
tracked 文件清单写入权限受限的临时文件，删除前逐块比对重新读取的清单，
避免大型仓库触及内存输出上限。detached HEAD 先检查直接指向它的引用，再按需检查提交历史；
找到一个保留引用后停止，无法在时限内确认时继续保留 worktree。
清理预检禁用 partial clone 的按需 fetch，缺少对象而无法确认引用时保留 worktree。
子模块的修改、未跟踪文件和 HEAD 变化按完整 Git 状态检查。含已初始化 submodule 的
worktree 符合清理条件时，目录和对应 worktree 元数据里的子模块仓库一起删除；不会解除
主目录、选中、置顶、排除、锁定或正在执行 Git 操作的保护。移除前再次核对状态，日志记录
是否使用 `--force` 及最终结果。Git 预检时限为 30 秒，大目录移除时限为 300 秒。

## 诊断日志

本机诊断日志写入 `~/Library/Logs/AgentGit/agentgit.jsonl`，Settings → Worktrees 中可通过
Show Logs in Finder 打开。每轮清理带独立 ID，记录触发方式、闲置截止时间、项目与 worktree、
检查阶段、活动时间、保留原因、删除结果和错误。Git 命令记录实际程序路径、参数、工作目录、
进程 ID、耗时、退出码、输出字节数及 stderr，包括成功命令产生的警告。应用启动和退出也记录版本与时间。

日志在独立串行队列写入，不记录 stdout、文件正文、stdin 或环境变量；URL 凭据和授权字段
会被遮盖。每份日志最多 5 MiB，保留三份轮转备份；单条最多 256 KiB，超长参数和输出会注明
截断及原始字节数。目录权限为 `0700`，文件权限为 `0600`。正常退出时等待已提交的日志写完。

## 最近活动时间

排序不直接采用目录 mtime。构建产物和依赖安装会制造大量与 review 无关的文件
事件。

```text
last_activity_at = max(
  HEAD reflog 的最近变化,
  HEAD commit 时间,
  Git status 中 changed / untracked 文件的最近 mtime
)
```

App 在前台通过 FSEvents 合并仓库文件变化并刷新受影响的 worktree，后台每隔 10 分钟刷新全部项目。
活动时间不采用会被 `git status` 缓存写入改变的 index mtime。
项目顺序由拖拽操作保存。项目内部使用 `last_activity_at` 倒序排列 worktree，
排序时间与列表显示时间完全相同；时间相同后按名称排列。侧栏使用稳定的 `now / 5m / 3h /
2d` 紧凑文本，仓库状态没有变化时不为相对秒数持续重绘列表。

## Review 模型

Review 工作区支持以下范围：

- **Working**：unstaged changes；
- **Staged**：index vs `HEAD`；
- **Commit**：单个提交按 first-parent 展开；
- **Commit Range**：两个提交端点之间的完整变化。

History 提供提交列表（作者、日期、短 hash、
分类 ref 徽标、彩色拓扑轨道）与提交内文件级 diff，merge commit 按 first-parent
展开。提交列表以当前 HEAD 为固定快照，每页读取 100 条记录，滚动到底后继续加载更早
提交。拓扑显示最多五条轨道，其余分支折叠到汇总轨道，避免挤压提交标题。Working 分组
包含 unstaged 与 untracked 文件。Commits 搜索默认匹配完整提交 message，使用
`author:姓名` 搜索作者；搜索同样固定当前 HEAD、支持分页，并在输入变化时取消旧查询。
当前 worktree 最近使用的八个搜索结果在内存中保留完整分页位置，Back / Forward 返回时无需
重复执行相同的 `git log` 查询。单项最多驻留 2,000 个提交或 2 MiB，全部搜索缓存最多
8 MiB；超过限制的当前结果继续显示，但不会进入返回缓存。
Pending 与提交选择保持互斥；移除最后一个提交选择时自动回到 Pending。多提交选择显示为
两个端点之间的 Commit Range；一次选中三个以上提交时保留最新与最旧两个可见端点，界面、
Back / Forward 与重启恢复使用同一范围。
History、搜索、分页和提交详情错误都在原位置提供 Retry。
Review 使用连续文件流，
支持 split / unified、分组折叠、分组与文件双层
吸顶、行内差异和轻量语法高亮。Diff 布局、上下文行数与忽略空白由全局
Settings 管理并跨启动保存。
设置窗口使用独立的 Review / Worktrees / Agents 页面。
主窗口使用系统统一工具栏，显示当前仓库和分支，提供导航、History、Focus、刷新、Pull / Push
和会话入口。项目侧栏使用原生列表材质与选中态；Diff 布局使用系统分段控件，审阅进度、
折叠与 hunk 导航固定在差异区顶部。图标使用 SF Symbols，基础颜色随系统外观变化。
Diff 正文使用 AppKit `NSTableView` 复用可见行，数万行变更不会交给 SwiftUI 为每行维护布局
和无障碍节点；Diff 聚焦时可用 `⌥↓` / `⌥↑` 在 hunk 间导航，`Tab` / `Shift-Tab`
在操作控件间切换。文件与 hunk 的常用操作按钮保持可见，键盘焦点有明确的描边。
主窗口最小尺寸为 1040×680 点；项目侧栏和提交导航在窄窗口分别压缩到 240 与 200 点，
Review 保留至少 490 点。离屏坐标检查要求文件、hunk 的 Stage、Unstage、Discard 全部位于
窗口边界内。
自动性能门槛使用 40,000 行 Diff 验证首次行模型构建低于一秒，并要求 Reviewed 标题更新低于
250 毫秒且不增加行重建次数。
`⌘F` 聚焦当前导航筛选框，`⌘1` / `⌘2` 聚焦 Commits 与 Files，`⌘↑` / `⌘↓`
在改动文件间移动，`⌘←` / `⌘→` 返回或前进到此前查看的 Pending、commit 或 commit range，
并恢复当时的 Commits / Files 页面与 History 搜索条件。
Diff 表格保留原生键盘焦点环并提供 `Diff Review` VoiceOver 名称；`Tab` / `Shift-Tab`
移动 hunk，`⌘C` 复制选中行，Escape 取消文件或 hunk 的 Discard 确认。图片 Before / After
面板分别朗读路径、像素尺寸、文件大小和加载状态。
超宽代码行只在代码裁剪区域响应横向滚动，行号、hunk 标题、文件标题和操作按钮保持固定；
可滚动宽度与位置按 hunk 独立保存，同一 hunk 的 split 左右栏同步，其他 hunk 不受影响。
每个文件可在 changed hunks 与 whole file 上下文之间切换，吸顶文件标题和右键菜单
提供相同入口。Hunk 标题优先显示 Git 提供的函数或作用域名称，悬停标题时在左侧显示
Whole File Context 按钮。相邻 hunk 之间使用独立的上下文边缘按钮，每次展开最多 20 行，
展开后保持下一个 hunk 的屏幕位置。Whole File 显示与隐藏使用代码行号锚点保持当前代码
位置。已展开上下文使用来源 Diff 的稳定内容身份；代码变化但行数不变时也会立即重建对应
行，避免缓存刷新后继续显示旧内容。
文件可标记 Reviewed；状态绑定当前 diff 内容指纹，内容或 Working / Staged
范围改变后自动失效。键盘移动文件焦点或切换 Reviewed 时只更新变化的文件标题与吸顶标题，
通过文件索引直接定位，不会扫描代码行、重建代码行或重新计算 hunk 宽度。
每个 worktree 保存最后使用的 Pending、commit 或 commit range 上下文；commit/range 同时保存
精确选择的提交 ID，并保存 Commits / Files 导航页和 History 搜索条件。重新打开应用或切换
回来时，从 History 与 Diff 缓存恢复对应 Review、折叠状态、Reviewed 状态、滚动位置和导航
页；目标提交位于后续分页时自动加载到对应页面并滚动到选中行，提交已经不可用时回到
Pending。
Files 导航与 Diff 文件标题的 `…` 菜单或右键菜单可以打开当前工作副本、使用 Visual Studio Code
打开、在 Finder 中定位，以及复制相对或绝对路径；已经删除或只存在于历史提交中的文件
会禁用打开操作并保留父目录定位。
Pending 的 Files 导航按 Working / Staged 分组，同一路径的两份 Diff 保持独立选择；列表获得
键盘焦点后按 Space 执行当前文件的 Stage 或 Unstage，右键菜单提供相同动作。submodule 仅有
内部 dirty 内容时继续隐藏无法生效的 Stage。
点击 Diff 的文件标题、hunk、代码行、图片、提示行或右键菜单会同步当前文件；该同步不会把
文件标题强制滚到顶部，随后使用 `⌘↑` / `⌘↓` 会从实际点击的文件继续导航。
重命名文件在文件导航和 Diff 文件头中显示旧路径 → 新路径。系统可识别的图片格式
使用等宽 Before / After 面板审阅，Working、Staged、单个提交和提交范围均读取对应的
真实 Git blob；新增与删除图片保留空侧说明。chmod、纯重命名、复制以及空文件新增或删除
等没有文本 hunk 的变更显示 Git 元数据摘要，并纳入 Reviewed 内容指纹。
基础 Diff 按最多 24 个文件分批读取，Working 与 Staged 并行执行，完成一个批次就立即进入
连续审阅区域。单次 patch
输出在读取进内存前限制为 8 MiB，过大的批次自动拆分到单文件；超过 50,000 行的
单文件保留精确 numstat 并显示有界状态，避免构造全部代码行对象。
批次遇到无法按 UTF-8 解码的文本 patch 时继续拆分到单文件；对应文件显示编码说明和
精确增删统计，同批其它文件仍正常呈现。Working、Staged、单个提交和提交范围使用相同的
隔离规则。
图片、Whole File 和额外上下文按文件隔离错误；单个附加内容失败时保留基础 Diff 与其他
已加载文件，Retry 只重新读取失败项。单个图片 blob 的预览上限为 32 MiB，超过上限时不把
完整内容读入内存。图片使用独立任务生成最长边 2048 像素的预览，预览缓存上限为 128 MiB；
App 进入后台时取消正在解码的可见图片，重新激活后继续生成预览。
基础 Diff、图片、Whole File、Retry 和额外上下文都绑定完整加载身份；worktree 内容、Review
上下文、Diff 设置或文件集合变化后，旧任务只能写入旧缓存，不能更新当前 Review 状态。
后台期间保留已经恢复的 Review 内容并禁用 Git 写操作；`Updating` 只表示真实存在的项目、
worktree 刷新任务，缓存缺少旧版时间字段时不会长期显示伪刷新状态。
untracked symlink 按 Git blob 语义显示链接目标路径文本，不跟随链接读取仓库外内容，也不因
文件名扩展误判为图片。

## Git 集成边界

首版直接调用系统 Git，使用稳定、机器可解析的输出：

```text
git worktree list --porcelain -z
git status --porcelain=v2 -z --branch --no-ahead-behind --untracked-files=normal
git ls-files --others --exclude-standard -z -- <untracked-directories>
git rev-list --left-right --count HEAD...@{upstream}
git diff --no-ext-diff --no-color
git diff --cached --no-ext-diff --no-color
git log -z --format=<unit-separated>
git show --format= --name-status -z --diff-merges=first-parent
```

Git 写操作限定为 Stage、Unstage、Discard 文件 / hunk / 行，以及当前分支的
fast-forward-only Pull、Push 与 Publish，以及用户启用的闲置 worktree 自动清理；不提供 commit、reset 或 worktree 创建。
没有 upstream 的分支使用 `origin` 或唯一 remote 完成 Publish 并设置 upstream；多个无
`origin` remote 时返回明确选择提示。Discard 文件与 hunk 使用原按钮二次确认，选中行使用
右键确认子菜单。执行 Discard 前，tracked 文件和行 / hunk 保存完整副本，未跟踪文件或目录
整体移动到 macOS 废纸篓中的 AgentGit 恢复包；恢复包包含 worktree、相对路径、操作类型和
时间。submodule 恢复包额外保存丢弃前的 HEAD、binary patch 与未跟踪文件。submodule
提交指针变化通过强制 checkout 恢复到父仓库记录的提交；只有内部 dirty 内容且父仓库
gitlink 未变化时隐藏无法生效的 Stage，并保留 Discard。rename 的 Stage / Unstage 同时处理
新旧路径。Discard 确认在三秒后、行复用时或执行其他操作时自动失效。submodule 路径解析后
必须仍位于 worktree 内，外部 symlink 会被拒绝。unmerged 文件使用 ours 与工作副本之间的 Diff 展示冲突标记，只提供解决后的整文件
Stage；无效的 Discard、hunk 和行操作保持隐藏。Pull / Push 运行时可取消，
取消会终止底层 Git 进程；界面显示“cancellation requested”，避免在远端可能已经接收更新
时承诺操作已经回滚。取消后使用独立任务刷新原 worktree，父任务的取消状态不会终止这次
刷新。远程 Git 命令实际返回后即判定完成；成功和取消请求使用带文字的紧凑状态胶囊，失败
在当前 worktree 标题区域显示完整错误。分叉分支的 Pull 保持 fast-forward-only，Push 由远端
执行正常的 non-fast-forward 保护。
远程命令时限为五分钟，错误
输出最多保留 2 MiB 并持续排空剩余内容。远程命令
关闭不可见的终端交互，已有 SSH key、credential helper 和系统 Keychain 仍可正常使用。
任一 Stage、Unstage、Discard、Pull 或 Push 运行期间禁用其他 Git 写操作；滚动、复制、
Reviewed 标记和 Whole File 切换保持可用。操作完成后保留当前 Review，直到新的状态快照接管，
避免短暂空白或新 Diff 被旧清理覆盖。Git 写入成功但状态刷新失败时明确说明操作已经完成、
保留旧 Review 并暂停后续写操作；Refresh 成功后恢复。写操作界面结果绑定发起时的 worktree
与递增请求序号；切换 worktree 后，旧操作可以完成仓库处理，但不能修改新页面的 spinner、
错误或远端操作反馈。

暂不引入 libgit2。系统 Git 对 worktree、attributes、diff driver、LFS 和用户已有
配置的兼容性更接近真实命令行行为；性能问题先通过并发调度、缓存和增量刷新
解决。

## 工程结构

```text
AgentGitCore       Git 命令、解析、领域模型、项目持久化
AgentGitIntegrationShared  Agent 会话、Skill 登记与持久化
AgentGitApp        SwiftUI App 外壳与 AppKit 高性能视图
```

Git 命令异步执行，进程等待不阻塞并发线程池；stdout / stderr 使用持续排空的内存 pipe，
大输出达到上限后只继续统计字节数，不再扩张内存，也不为每条命令创建临时文件。
AgentGit 的 Git 命令及其子进程使用临时配置 `maintenance.auto=false` 和 `gc.auto=0`，
避免操作过程中启动脱离应用的自动维护；不修改仓库或全局 Git 配置。同一 common gitdir 下的
全部 worktree 都使用这项保护，兼容使用不同 Git 可执行文件的调用方。
Pending、commit 与 range Diff 在进入批处理前按 `GitFileChange.ID` 稳定去重，避免异常重复输入
造成重复 Git 工作或字典构造终止。
UI 不直接创建 `Process`。所有路径
以绝对路径进入 core，命令参数使用 argv，不拼 shell 字符串。status 允许 Git 写回
fsmonitor token、untracked cache 与 index stat cache，避免大型仓库每轮重新扫描全部索引项。
本地状态扫描和 worktree 元数据命令分别使用 30 秒和 15 秒时限；超时后先终止 Git 及其
子进程，500 毫秒后强制结束仍未退出的进程。ahead / behind 或 numstat 失败时保留已经读取的
文件状态与 Review 入口。worktree 行保持固定两行，用警告图标和悬停说明呈现补充信息错误；
`↑N / ↓N` 保持紧凑显示，悬停和 VoiceOver 会说明对应 upstream 以及 ahead / behind 的完整
提交数量；
缺失的 upstream 使用紧凑说明并禁用 Pull / Push，选中 worktree 后可在工作区错误条重试。

最后一次成功的项目快照保存在
`~/Library/Caches/com.sigma.agentgit/project-snapshots-v1.json`。缓存包含 worktree 清单、状态
计数、增删行数、活动时间、branch 信息和项目成员完整标记，文件权限为
`0600`。App 启动时立即恢复侧栏；完整缓存直接提供启动首帧，缺少的项目或成员按需加载。
文件变化、后台定时刷新和手动刷新会更新 worktree 状态，成员事件同时更新项目清单。
只在事件处理完成后保存对应游标，重启时继续读取未完成的仓库事件。
旧版缓存自动迁移，缓存使用版本化 JSON 和原子写入，失败刷新保留此前
的成功内容。每次更新前还会保留
`~/Library/Caches/com.sigma.agentgit/project-snapshots-v1.backup.json`；主文件损坏或写入中断
时自动恢复上一份有效快照。新增的快照字段使用兼容默认值读取，应用升级不会因此丢弃全部
项目数据。JSON 语法正确但包含重复 project / worktree ID 时同样视为缓存损坏，优先恢复
有效备份；没有备份时保留项目路径并重新读取 Git 状态，不会在字典构造阶段终止进程。

固定 HEAD 已经加载的 History 分页、Pending 基础 Diff，以及固定 commit / commit range 的
message、文件列表和基础 Diff 保存在
`~/Library/Caches/com.sigma.agentgit/review-content-v1/`。History 缓存键包含 worktree、HEAD
和分页大小；Pending Diff 的聚合缓存键包含 HEAD、完整 status、增删统计、文件活动时间和 Diff
设置，另有跨快照复用的文件缓存，校验两侧对象 ID、工作区内容、文件模式、Git 属性、有效配置、
Git 版本、路径和 Diff 设置。只更改一个文件时，其他文件继续使用各自的结果；计算完成后再次
校验身份，无法确认或超过读取预算的文件重新计算。历史 Review 使用不可变 commit OID 或 range 端点与 Diff 设置。文件内容、index、HEAD
或设置变化都会使用新的缓存项。单项缓存上限为 32 MiB，总量上限为
128 MiB，达到上限后按最近使用时间清理到 112 MiB；缓存文件使用原子写入和 `0600` 权限。用户已经展开的 Whole
File 与额外上下文按文件和 Diff 设置保存，重启后恢复相同 Review 状态时直接读取缓存。图片
预览继续按需读取。聚合内容最多保存 8 MiB，更大的 Diff 使用文件级清单，已有文件级清单
继续按分段更新。相同内容不重写，变化分段完成后原子更新清单。大型 commit 与 commit range Diff 同样按文件保存，重复进入历史
Review 时直接恢复。启动时在 8 MiB 预算内先恢复尽可能多的 Pending 文件，其他文件随后从
本地缓存补齐，侧栏和窗口首帧不会等待整个大型 Review。Pending、commit 和 commit range
Diff 每完成一个读取批次就保存文件级缓存和部分完成标记；应用退出或任务取消后，下次进入
相同 Review 会直接显示已完成批次并读取缺少的文件，全部文件完成后再写入完整标记。分段
损坏时保留已恢复内容并重新读取完整 Diff。
当前进程读取过的 History、Pending Diff 和历史 Diff 会保留在内存中，重复切换页面
无需再次解码缓存文件。文件缓存与原有四类内容共用最近使用淘汰策略，最多保留 24 项且序列化大小合计不超过
16 MiB；超过预算的单项仍返回当前 Review，但不会长期驻留内存。项目快照或 Review 内容写入
失败时在主窗口显示可关闭的缓存错误，后续保存成功后自动恢复。

Diff 表格按文件保留已有内容行、双栏配对和代码宽度。变化文件重建自己的内容行，在一次批量
更新中提交插入、删除和重载；其他文件的行控件、滚动位置和选区继续保留。Whole File、上下文
展开和读取批次到达时采用同一更新方式；切换 Review 或分栏模式时重新建立全部行。
Reviewed 标记和展开上下文的展示数据按内容版本复用，界面重复绘制时不再遍历相同的改动行；
内容、状态或展开范围变化后重新计算，离开当前文件列表时清理对应数据。分批结果按预先建立的
文件索引合并；读取、解析和首次标记计算明确在并发执行器上完成，发布结果前核对当前 Review。
Whole File 和额外上下文的同一完整文件请求复用正在进行的读取，最后一个调用方
取消后终止读取；缓存未命中时沿用已经核对的身份，计算完成后仍重新校验内容。

批量 patch 分行解析，超过单文件行数上限后只继续计数，不保存后续行。超过 65536 个 Unicode
标量的长行保留整行差异底色，跳过字符级细分。刷新时，改动文件的元数据同时用于增删统计缓存
和最近活动时间，避免重复读取。缓存写入和删除按大小增量记账，超出预算或距离上次核对超过
一分钟或发现外部目录变化时再读取目录，目录内容稳定时直接按索引清理。

App 在后台每轮刷新完成后等待 10 分钟，再刷新全部项目；回到前台时取消后台定时任务及其刷新。
后台保留文件事件，回到前台后合并处理；前台持续监听文件、index、引用和 worktree 成员变化。
监听范围扩大时补读新增范围，忽略 Git 不关注的文件写入，规则文件变化仍会刷新。
Git 写操作和清理期间保留事件，操作结束后继续处理。监听不可用时提供错误提示并启用定时刷新。
关闭主窗口后继续后台定时刷新。
正常退出通过 macOS termination reply 等待 Review 状态与项目快照原子写入完成，再结束进程。
状态扫描使用 `--no-ahead-behind` 和 `--ignore-submodules=dirty`；未跟踪目录按需展开，
ahead/behind 单独读取。切换 worktree 立即使用可用快照，只有缺少完整状态时自动读取。
完成 Git 写操作后刷新当前 worktree。工具栏与 `⌘R` 刷新当前项目的全部 worktree，`⇧⌘R` 刷新全部项目。
History、搜索、commit message、提交文件列表与范围文件列表统一使用 30 秒时限；History 与
文件列表单次输出上限为 8 MiB，commit message 上限为 2 MiB。非法分页参数返回可恢复错误，
不会触发运行时终止。
非选中 worktree 只读取 submodule 提交指针以控制扫描成本；当前 Review 的 worktree 使用
完整 submodule 状态，因此 tracked / untracked 内容修改可以显示并执行 Discard。完整项目
刷新先发布当前 worktree 的轻量状态，再补充 submodule 内容状态。
刷新请求按项目和 worktree 记录版本，新请求会取消同目标的旧 Git 进程；旧结果无法覆盖
较新的状态。完整项目刷新优先读取当前选中的 worktree，并在每个 worktree 完成后立即更新
侧栏。全部项目按每批两个项目读取，每个项目最多同时读取两个 worktree。ahead / behind 按实时 HEAD 与
upstream OID 缓存；diff numstat 使用 HEAD、index、Git 属性、status 与变更文件元数据构成
短期指纹缓存，并把统计范围限制在实际变更路径。刷新失败时保留最后一次成功的状态和统计，
并附加本次错误信息。

## Agent 会话关联

会话与 worktree 的关联记在 `~/Library/Application Support/AgentGit/associations.json`，
只留在本机、按私有文件权限存放，每个 worktree 最多关联三个会话，超出后按更新时间淘汰。
Settings 的 Agents 页面显示已登记的会话数量；存储 JSON 损坏时提供 `Repair Storage`：
原文件以 `0600` 权限移动到唯一 `.corrupt-<UUID>.json` 备份，再原子重建空存储，
正常数据不会自动删除。

主 App 只在选中 worktree 的标题栏显示会话按钮，侧栏项目列表保持纯 Git 信息。点击按钮
直接打开对应会话，悬停显示会话详情。Codex 会话使用规范 thread UUID 打开；Claude 的规范
session UUID 与 Desktop 内部 session ID 可能不同，主 App 在后台只读 Claude Desktop 的
JSON 会话索引，按精确 `cliSessionId` 解析当前 Desktop session ID，不读取 transcript 正文。
索引映射已经失效的关联显示为 Unavailable，并排到仍可打开的会话之后，可从右键菜单移除。

AgentGit 不扫描 transcript，唯一的例外是查 Codex `create_worktree` 建的 worktree 属于哪个线程时，
只读 worktree 创建之后仍在写入的 Codex 会话日志，见下文「Worktree 创建者」；也不启动额外后台服务。
关联数据的读取、合并与原子写入通过
独立锁文件串行执行，数据文件与锁文件权限均为 `0600`。

`associations.json` 不再新增关联，只保留已有数据。

### Worktree 创建者

Settings → Agents 的 `Install Hook` 把脚本写到
`~/Library/Application Support/AgentGit/git-hooks/post-checkout`，并在全局 git 配置里登记
`hook.agentgit.event = post-checkout` 与 `hook.agentgit.command`。这是 git 的配置式 hook，
和仓库自带的 hook（如 git-lfs）一起运行，不改 `.git/hooks` 或 `core.hooksPath`；
`Remove Hook` 删除 `hook.agentgit` 配置段。

此功能需要 `/usr/bin/git` 支持 Git 2.54 的配置式 hook；不支持时安装会显示升级提示。
可通过更新 Xcode Command Line Tools 升级系统 Git，其他 Git 客户端功能仍可使用。

创建者记录由 AgentGit 保存在 `~/Library/Application Support/AgentGit/worktree-creators/`，
每个 worktree 一个 JSON 文件，文件名是 worktree 路径的 SHA-256，同一路径后写的覆盖先写的；
AgentGit 不往仓库的 `.git` 里写东西：

```json
{
  "created_at": "2026-01-01T00:00:00Z",
  "host_session_id": "local_11111111-1111-4111-8111-111111111111",
  "provider": "claude",
  "session_id": "22222222-2222-4222-8222-222222222222",
  "source": "git-hook",
  "title": "Example session",
  "worktree_path": "/Users/developer/projects/agentgit/.claude/worktrees/example"
}
```

记录有三种来源：

| `source` | 创建方式 | 会话来源 |
|---|---|---|
| `git-hook` | agent shell 里执行 `git worktree add`，包括 Claude 的 `EnterWorktree` | 环境变量，依次认 `CLAUDE_CODE_SESSION_ID`、`CODEX_THREAD_ID`、`CLAUDE_CODE_HOST_SESSION_ID` |
| `claude-desktop` | Claude Desktop 新建会话时自己建的 worktree | Desktop 会话索引里 `worktreePath` 等于该路径的会话 |
| `codex-app` | Codex App 在 `~/.codex/worktrees/` 下建的 worktree | `~/.codex/state_<n>.sqlite` 里以该路径为 `cwd` 的最早线程；线程里调用 `create_worktree` 建的，取会话日志里 `worktreeGitRoot` 等于该路径的那次调用所在线程 |

- hook 只有 Desktop 会话 ID 时，从该会话的 Desktop 索引读出 `cliSessionId`；Claude 的标题和
  `host_session_id` 只在索引的 `cliSessionId` 与会话一致时写入。Codex 标题取
  `~/.codex/session_index.jsonl` 里该线程最新的 `thread_name`。hook 写完后用
  `notifyutil -p com.sigma.agentgit.worktree-creators.changed` 通知 AgentGit 重读。
- 宿主自己建的 worktree 不经过 agent shell，hook 认不出会话，改写待查标记
  `worktree-creators/pending/<路径哈希>` 并发同一个通知。AgentGit 不论在前台还是后台，
  都每 10 秒按宿主元数据把所有待查路径查一次，查到或超过 1 分钟后删掉标记；启动和回到前台时
  也会接着处理剩下的标记。
- 启动时和每次项目刷新（worktree 列表重新发现）完成后，对还没有记录的 worktree 再按宿主元数据
  查一次。会话创建时间和 worktree 的 git 管理目录创建时间要在一小时内；Codex 会话日志只查一天内
  建的 worktree，并且只读 worktree 创建之后仍在写入的日志。
- AgentGit 自己执行的 git 命令不带 agent 会话的环境变量，不会被记到任何会话名下。
- worktree 或它的 git 管理目录已不存在、或 git 管理目录比记录晚一小时以上创建（同一路径删掉
  重建过）的记录不再显示。git 删除 worktree 时没有 hook，这些记录文件由 worktree 定期清理
  在每次运行末尾删除，同一路径较旧的重复记录一并删除；`/Volumes` 下未挂载的外接卷上的记录保留。
- `git worktree add --no-checkout` 不触发 post-checkout；IDE 等不调用 git 命令行的工具、
  以及不在 agent 会话里、宿主元数据也查不到的 worktree 都没有记录。

worktree 页面工具栏的会话按钮把创建者会话排在最前，点击打开该会话，按钮宽度随标题变化；
创建者记录不能在这里移除。All Worktrees 列表在目录名后显示创建者。标题优先取宿主索引里的最新值，其次是记录里的
`title`，都没有时显示 provider 和会话 ID 前 8 位；悬停显示 provider、会话 ID 和创建时间。
右键 `Open Creator Session` 打开该会话：Codex 用 `codex://threads/<id>`，Claude 按
Desktop 会话索引解析出的 Desktop 会话打开。

## M1 验收

- 能添加至少三个项目并在重启后恢复；
- 一个项目的主 checkout 和多个 linked worktree 自动归组；
- worktree 排序能随真实 Git-visible 修改更新；
- staged、unstaged、untracked 状态计数正确；
- 工作区 Diff 与命令行 Git 输出一致；
- 单个失效路径或损坏仓库不会阻塞其它项目；
- 空项目、大量 worktree 和大 Diff 都不会阻塞主线程；
- `swift build` 通过。
