# 侧栏原生样板

该样板独立于主应用，由 SwiftUI `ImageRenderer` 渲染。内容是用于检查排版的固定示例；不会读取仓库、切换会话或修改应用设置。

## 对照基准

使用用户提供的 Claude Desktop 两行选中态截图。原图为 982 × 2036 像素，裁掉外部黑边后的内容区为 910 × 1964 像素。样板使用 455 × 982 逻辑点，以 2× 导出，避免应用当前缩放影响校准。

同文校准保留参考文案，检查文字、间距、背景和选中态。AgentGit 映射版将日期换成 repo，将条目换成 worktree，所有 worktree（含置顶）显示分支与会话两行，并保留显示更多入口。

置顶只影响 worktree 所属 repo 内的排序，置顶项排在该 repo 的列表前面，分支行右侧显示低对比度的图钉。repo 分组顺序保持独立。

## 字体与几何

| 对象 | 样板值 |
| --- | --- |
| 字体 | Anthropic Sans Text Light；直接指定字体实例 |
| 导航与搜索 | 16 pt |
| 分支标题 | 15.7 pt |
| 会话与分组标题 | 14.5 pt |
| 正文左缩进 | 22 pt |
| 标题行盒 / 会话行盒 | 23 / 21 pt |
| 两行间距 | 3 pt |
| 普通行高度 | 60 pt |
| 选中行高度 | 57.5 pt |
| 选中行左右缩进 | 9.5 / 12.5 pt |
| 选中圆角 | 7 pt |

字体选择和尺寸是本机原生渲染与该截图的校准结果，不代表 Claude 官方规范。中英文均使用系统字体回退机制；不同平台或字体渲染器仍可能存在笔画边缘差异。

## 颜色

| 用途 | sRGB |
| --- | --- |
| 侧栏底色 | `#FAF9F7` |
| 主文字 | `#41403D` |
| 会话与分组 | `#76746E` |
| 选中主文字 | `#0B0B0B` |
| 选中底色 | `#EDEBE7` |
| 悬停底色 | `#F1F0EC` |
| 搜索底色 / 边框 | `#FDFDFB` / `#DFDFDD` |

普通与选中使用相同字号和字重，选中通过底色及主文字颜色区分。悬停色是样板定义，静态参考图不包含悬停状态。

## 生成与验证

```sh
bash Design/Sidebar/render.sh
python3 Design/Sidebar/compose.py /absolute/path/to/claude-sidebar-reference.png
```

运行环境需要 macOS、SwiftUI、Pillow 和本机 Anthropic Sans 字体。渲染器会明确检查字体是否存在。`compose.py` 校验画布、选中背景边界、背景颜色，以及所选文字区域的纵向位置，并输出 `measurements.json`。

`output/review.html` 为包含全部图片的独立对照页，可离线查看并调节叠图透明度。`comparison.png` 是同文对照，`agentgit-comparison.png` 是内容映射对照，`row-states.png` 是行状态样板。

该样板用于视觉评审；折叠、键盘焦点、点击区域和窄侧栏截断在接入主应用时另外验证。
