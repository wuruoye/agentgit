# Review 原生样板

用独立 SwiftUI `ImageRenderer` 检查提交列表、Review 顶栏和多文件 diff。样板直接复用
主应用的 `AgentGitTypography` 与代码配色，界面文字采用 Anthropic Sans Text Light，
代码使用 Menlo。输出目录中的真实提交内容与截图只用于本地对照，不加入版本控制。

## 样板内容

样板按 Claude Desktop（Code 标签页）diff 审阅面板的布局重画 Review 区：横跨全宽的顶栏、
上半文件树下半 Commits 的左栏、单行浅灰文件标题、「N unmodified lines」分隔行，以及
单列行号加增删竖条的代码行。颜色、字体和语法高亮直接取主应用的 `AgentGitPalette`、
`AgentGitTypography` 和 `DiffSyntaxHighlighter`，同一份 fixture 输出浅色和深色两张图。

| 对象 | 100% 下的逻辑值 |
| --- | --- |
| 顶栏 / 标题 | 44 pt / 14.5 pt，Light |
| 文件树行 / 字号 | 26 pt / 14 pt |
| 提交行 / 标题 / 元数据 | 54 / 14 / 12 pt，SHA 用等宽字体 |
| 文件标题行 / 文件名 / 目录 | 36 / 14 / 13 pt |
| 折叠上下文行 / 无折叠的 hunk 行 | 44 / 24 pt |
| 代码 / 代码行高 / 增删竖条 | Menlo 13 pt / 20 pt / 3 pt |

`states.png` 展示普通、悬停、选中、开关打开和禁用外观。

## 生成

先将截图保存到本地，再只读采集与截图相同的 Git 提交：

```sh
python3 Design/Review/capture-fixture.py /absolute/path/to/repository COMMIT Design/Review/output/fixture.json
bash Design/Review/render.sh
python3 Design/Review/compose.py /absolute/path/to/current-screenshot.png
```

`render.sh` 输出 `proposal.png`（浅色）、`proposal-dark.png`（深色）、`proposal-narrow.png`
（收起左栏）和 `states.png`。`compose.py` 需要同尺寸的当前界面截图才能生成下面的对照；
`comparison.png` 为整体同尺寸对照，`detail-comparison.png` 为提交列表与前两个文件的局部
对照，`proposal-in-window.png` 将原生样板放回原窗口。`review.html` 内嵌全部图片，可离线
并排、同步滚动或调整叠图透明度。`measurements.json` 记录尺寸、缩放、字体和内容核对结果。

这是一份静态原生样板。按钮用于外观评审；Git 操作、实际 hover 动画和滚动交互在接入
主应用时验证。
