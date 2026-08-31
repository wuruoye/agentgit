# AgentGit

状态：原生 macOS 开发版本，可用于日常 worktree review。

AgentGit 首先是一款现代、原生、worktree-first 的 Git 客户端。它面向同时使用
多个 worktree 的开发方式，把代码审阅体验和本地性能放在首位。

Agent 会话关联通过可选的 AgentGit Skill 插件完成，Git 客户端主路径保持独立。

## 本地运行

```bash
swift test
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

本地默认使用开发证书签名；需要改用其它证书时设置
`AGENTGIT_SIGNING_IDENTITY`。

## 产品主路径

```text
添加项目
  -> 自动发现该仓库的全部 worktree
  -> 项目保持手动拖拽顺序
  -> 项目内部按列表展示的最近更新时间排列 worktree
  -> 每个项目显示最多四个近期活跃 worktree
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
4. 项目支持折叠和手动拖拽排序；每个项目默认显示最多四个近期活跃 worktree，
   其余 worktree 通过列表末尾控件展开；
5. 选择 worktree 后展示 changed-file 导航、unified diff 和提交历史；
6. 项目列表与最后选中的 worktree 在下次启动时恢复；
7. Git 命令失败时在对应项目或 worktree 上显示明确错误和恢复操作，不让整个窗口失效。

侧边栏可按项目名、路径、分支、worktree 路径和 HEAD 短哈希搜索；`⌘P` 打开可搜索的
worktree 切换窗口，并直接使用已恢复的缓存快照。项目顺序同时提供拖拽与
Move Up / Move Down 菜单操作。侧栏、History、Files 和 Review 的筛选没有结果时
都在原位置提供 Clear Filter。筛选、折叠和列表重建不会清除当前 Review；已经移除的
worktree ID 也不会覆盖当前有效选择。

M1 不包含 commit、reset 或 worktree 创建删除。Git 写操作支持 Working / Staged 中的 Stage、Unstage 和 Discard，
粒度为文件、hunk 或选中行；当前分支另外提供 fast-forward-only Pull 与 Push。

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

FSEvents 监听 worktree、实际 Git 目录和公共 Git 目录，文件事件在 400 毫秒内合并，
只刷新受影响的 worktree。活动时间不采用会被 `git status` 缓存写入改变的 index mtime。
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
设置窗口使用独立的 Review / Agents 页面；打开 Review 页面不会启动 Agent 插件 CLI 检查，
切换到 Agents 页面后才刷新配置状态。
Diff 正文使用 AppKit `NSTableView` 复用可见行，数万行变更不会交给 SwiftUI 为每行维护布局
和无障碍节点；Diff 聚焦时可用 `Tab` / `Shift-Tab` 在 hunk 间导航。
主窗口最小尺寸为 1200×680 点；项目侧栏和提交导航在窄窗口分别压缩到 180 与 200 点，
Review 保留至少 590 点。离屏坐标检查要求文件、hunk 的 Stage、Unstage、Discard 全部位于
窗口边界内。
自动性能门槛使用 40,000 行 Diff 验证首次行模型构建低于一秒，并要求 Reviewed 标题更新低于
250 毫秒且不增加行重建次数。
`⌘F` 聚焦当前导航筛选框，`⌘1` / `⌘2` 切换 Commits 与 Files，`⌘↑` / `⌘↓`
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
worktree 或文件事件刷新任务，缓存缺少旧版时间字段时不会长期显示伪刷新状态。
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
fast-forward-only Pull、Push 与 Publish；不提供 commit、reset 或 worktree 创建删除。
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
AgentGitSkillBridge  Skill 状态检查、登记与本地通知命令
AgentGitApp        SwiftUI App 外壳与 AppKit 高性能视图
AgentGitCoreTests  porcelain / diff parser 与真实临时仓库测试
AgentGitAppTests   AppKit Review 布局、交互与离屏快照测试
AgentGitIntegrationSharedTests  Skill 与关联数据测试
```

Git 命令异步执行，进程等待不阻塞并发线程池；stdout / stderr 使用持续排空的内存 pipe，
大输出达到上限后只继续统计字节数，不再扩张内存，也不为每条命令创建临时文件。
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
计数、增删行数、活动时间、branch 信息、项目成员完整标记和对应的 FSEvents 游标，文件权限为
`0600`。App 启动时立即恢复侧栏；完整缓存直接提供启动首帧，再从缓存游标补收退出
期间的文件事件，只刷新发生变化的 worktree。worktree 成员元数据事件只核对成员清单；成员
没有变化时保留全部状态、统计与 Review 缓存，不读取各 worktree 状态。首次读取尚未完成时逐个保存已经取得的项目和
worktree；下次启动只补齐缺少的项目或成员。`git status` 已经写入快照的 index 缓存事件会
直接推进游标，外部 Stage、Unstage 和冲突处理仍按 index 指纹变化触发刷新。系统事件记录
缺失时执行完整刷新。旧版缓存自动迁移，缓存使用版本化 JSON 和原子写入，失败刷新保留此前
的成功内容。每次更新前还会保留
`~/Library/Caches/com.sigma.agentgit/project-snapshots-v1.backup.json`；主文件损坏或写入中断
时自动恢复上一份有效快照。新增的快照字段使用兼容默认值读取，应用升级不会因此丢弃全部
项目数据。JSON 语法正确但包含重复 project / worktree ID 时同样视为缓存损坏，优先恢复
有效备份；没有备份时保留项目路径并重新读取 Git 状态，不会在字典构造阶段终止进程。

固定 HEAD 已经加载的 History 分页、Pending 基础 Diff，以及固定 commit / commit range 的
message、文件列表和基础 Diff 保存在
`~/Library/Caches/com.sigma.agentgit/review-content-v1/`。History 缓存键包含 worktree、HEAD
和分页大小；Pending Diff 缓存键包含 HEAD、完整 status、增删统计、文件活动时间和 Diff
设置；历史 Review 使用不可变 commit OID 或 range 端点与 Diff 设置。文件内容、index、HEAD
或设置变化都会使用新的缓存项。单项缓存上限为 32 MiB，总量上限为
128 MiB，按最近使用时间清理；缓存文件使用原子写入和 `0600` 权限。用户已经展开的 Whole
File 与额外上下文按文件和 Diff 设置保存，重启后恢复相同 Review 状态时直接读取缓存。图片
预览继续按需读取。超过 8 MiB 的 Pending Diff 同时保存文件级清单；超过 32 MiB 的聚合内容
直接使用这些文件级缓存。大型 commit 与 commit range Diff 同样按文件保存，重复进入历史
Review 时直接恢复。启动时在 8 MiB 预算内先恢复尽可能多的 Pending 文件，其他文件随后从
本地缓存补齐，侧栏和窗口首帧不会等待整个大型 Review。Pending、commit 和 commit range
Diff 每完成一个读取批次就保存文件级缓存和部分完成标记；应用退出或任务取消后，下次进入
相同 Review 会直接显示已完成批次并读取缺少的文件，全部文件完成后再写入完整标记。分段
损坏时保留已恢复内容并重新读取完整 Diff。
当前进程读取过的 History、Pending Diff 和历史 Diff 会保留在内存中，重复切换页面
无需再次解码缓存文件。四类内容共用最近使用淘汰策略，最多保留 24 项且序列化大小合计不超过
16 MiB；超过预算的单项仍返回当前 Review，但不会长期驻留内存。项目快照或 Review 内容写入
失败时在主窗口显示可关闭的缓存错误，后续保存成功后自动恢复。

FSEvents 忽略 `fsmonitor--daemon` 的内部 cookie，并把这类空影响事件的游标写入启动缓存，
避免下次启动重复回放。App 进入后台时停止文件监听、取消 debounce 与正在运行的仓库刷新。
关闭主窗口时执行相同暂停流程；重新打开窗口后恢复监听并补收增量事件。正常退出通过 macOS
termination reply 等待 Review 状态与项目快照原子写入完成，再结束进程。
监听器保留最后收到的系统事件 ID。重新激活后先恢复监听，再补收后台期间的文件事件；完整
项目缓存不会重复读取成员清单。成员发生变化时只加载新增 worktree，直接移除已经删除的项。
新增、删除、移动、锁定和修复 worktree 会自动刷新项目清单；普通索引与文件变化仍只刷新
受影响的 worktree。工作区文件事件通过 `git check-ignore --stdin -z` 批量应用仓库自身的
ignore 规则；构建产物和生成目录只推进事件游标，tracked 文件继续触发刷新。公共 Git 目录
中的 branch 与 upstream ref 事件按具体 worktree 分发，普通 commit、fetch 和 push 不会扩大
成整个项目扫描。
状态扫描使用 `--no-ahead-behind` 和 `--ignore-submodules=dirty`；未跟踪目录按需展开，
ahead/behind 单独读取。FSEvents 自动刷新受影响 worktree；切换 worktree 立即使用可用快照，
只有缺少完整状态时自动读取。完成 Git 写操作后刷新当前 worktree。工具栏与 `⌘R` 刷新当前
worktree，`⇧⌘R` 刷新全部项目。
History、搜索、commit message、提交文件列表与范围文件列表统一使用 30 秒时限；History 与
文件列表单次输出上限为 8 MiB，commit message 上限为 2 MiB。非法分页参数返回可恢复错误，
不会触发运行时终止。
非选中 worktree 只读取 submodule 提交指针以控制扫描成本；当前 Review 的 worktree 使用
完整 submodule 状态，因此 tracked / untracked 内容修改可以显示并执行 Discard。完整项目
刷新先发布当前 worktree 的轻量状态，再补充 submodule 内容状态。
刷新请求按项目和 worktree 记录版本，新请求会取消同目标的旧 Git 进程；旧结果无法覆盖
较新的状态。完整项目刷新优先读取当前选中的 worktree，并在每个 worktree 完成后立即更新
侧栏。全部项目按每批两个项目读取，每个项目最多同时读取两个 worktree；FSEvents 触发的
重复事件在当前刷新完成后合并，最多同时读取两个 worktree。ahead / behind 按实时 HEAD 与
upstream OID 缓存；diff numstat 使用 HEAD、index、Git 属性、status 与变更文件元数据构成
短期指纹缓存，并把统计范围限制在实际变更路径。刷新失败时保留最后一次成功的状态和统计，
并附加本次错误信息。

## Agent 会话集成

签名 App bundle 包含 Codex 与 Claude 两套 AgentGit 集成插件，以及
`Contents/Helpers/AgentGitSkillBridge`。Settings 的 Agents 页面可以独立启用、停用和更新
每套插件。当前能力包含 `Registration Skill` 与 `Session Jump`。

启用插件时，App 把随包资源复制到
`~/Library/Application Support/AgentGit/AgentIntegrations/`，再调用对应 Agent 的官方
插件 CLI 注册本地 marketplace、安装插件并验证版本与启用状态。Codex 插件标识为
`agentgit@personal`，Claude 插件标识为 `agentgit@agentgit`。Codex 停用操作移除插件，
Claude 停用操作保留插件并关闭加载；本地会话关联数据在两种情况下都会保留。

两套插件都包含 `agentgit-register` Skill、状态检查与登记脚本，以及签名后的本地
Skill bridge：

```text
<plugin>/skills/agentgit-register/SKILL.md
<plugin>/scripts/status.sh
<plugin>/scripts/register.sh
<plugin>/bin/AgentGitSkillBridge
```

Skill 的 description 覆盖编辑、生成、删除、移动、格式化、Stage、Commit、Merge、Rebase
等仓库写操作。Agent 在首次修改 worktree 前加载 Skill，并从宿主提供的当前任务元数据取得
规范 session ID；宿主没有提供稳定身份时静默跳过，禁止根据目录、标题、历史文件或更新时间
猜测会话。Skill 先调用 `scripts/status.sh`：已经关联时继续原任务，尚未关联时结合当前用户
请求组织不含敏感内容的会话标题与操作摘要，再调用 `scripts/register.sh`。

所有触发范围、身份要求、静默条件、标题摘要规则和失败处理都保存在 `SKILL.md`。
`AgentGitSkillBridge` 只执行确定性工作：验证 provider、session ID、标题和摘要，通过 `.git`
定位真实 worktree，检查现有关联并写入关联与审计数据。它不分析 Agent 命令，也不参与每个
tool call。登记操作幂等；同一 session 切换到另一个 worktree 后，新的登记会移动该关联。

关联数据由 AgentGit 自己保存，每个 worktree 最多关联三个会话。Skill 检查现有登记时更新
最近使用时间；新增会话超过上限后淘汰最久未使用的关联。主 App 通过分布式
通知即时更新，只在选中 worktree 的标题栏显示三个会话按钮，侧栏项目列表保持纯 Git 信息。
点击按钮直接打开对应会话，悬停显示会话详情。登记成功、登记被拒绝和移除结果
保存在 `~/Library/Application Support/AgentGit/registration-events.json`，最多保留最近
200 条，文件权限为 `0600`。旧格式的非登记事件在首次读取时自动丢弃并重写为当前格式。

Skill bridge 可以通过绝对路径 `AGENTGIT_DATA_DIRECTORY` 使用隔离存储；正常 App 配置没有
设置该变量，继续使用 Application Support。无效参数或相对数据目录会输出可读 stderr 并以
普通失败码退出。
Settings 同时显示本地关联数量。关联或审计 JSON 损坏时提供 `Repair Storage`：原文件以
`0600` 权限移动到唯一 `.corrupt-<UUID>.json` 备份，再原子重建空存储；正常数据不会自动
删除。

Codex 会话使用规范 thread UUID 打开。Claude 的规范 session UUID 与 Desktop 内部
session ID 可能不同；主 App 在后台只读 Claude Desktop 的 JSON 会话索引，按精确
`cliSessionId` 解析当前 Desktop session ID，不读取 transcript 正文。索引映射已经失效的
关联显示为 Unavailable，并排到仍可打开的会话之后，用户可从右键菜单移除。
重复关联通知会保留未变化会话的跳转结果；只有新增会话显示解析中，侧栏 badge 不会在
每次关联刷新时清空并重新排序。关联集合与已有结果一致时直接跳过 Claude Desktop 会话
索引扫描；App 从后台恢复时重新验证一次。

AgentGit 不扫描 transcript，也不启动额外后台服务。插件状态只在 Settings 的 Agents 页面
打开时读取，每条 CLI 命令的时限为 15 秒。配置检查与写入按 provider 使用最新操作令牌；
较早结果不会覆盖后续操作。多个 Skill bridge 进程通过独立锁文件串行执行关联数据的读取、
合并和原子写入，避免同时登记时丢失其它会话；数据文件与锁文件权限均为 `0600`。

## M1 验收

- 能添加至少三个项目并在重启后恢复；
- 一个项目的主 checkout 和多个 linked worktree 自动归组；
- worktree 排序能随真实 Git-visible 修改更新；
- staged、unstaged、untracked 状态计数正确；
- 工作区 Diff 与命令行 Git 输出一致；
- 单个失效路径或损坏仓库不会阻塞其它项目；
- 空项目、大量 worktree 和大 Diff 都不会阻塞主线程；
- `swift test` 与 `swift build` 通过。
