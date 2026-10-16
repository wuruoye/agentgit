# Review 原生样板

用独立 SwiftUI `ImageRenderer` 检查提交列表、Review 顶栏和多文件 diff。样板直接复用
主应用的 `AgentGitTypography` 与代码配色，界面文字采用 Anthropic Sans Text Light，
代码使用 Menlo。输出目录中的真实提交内容与截图只用于本地对照，不加入版本控制。

## 比较条件

- 缩放为 110%，所有字号、间距、按钮和代码行同步放大，再以 2× Retina 导出。
- 当前界面截图为 5120 × 2820 像素；审阅区裁剪坐标为 `(828, 104, 5120, 2756)`。
- 当前界面与样板均为 4292 × 2652 像素，提交导航宽度均为 792 像素。
- 使用同一真实提交的 3 个文件、4 个 hunk、`+4 −9`，保留全部 37 行 diff 内容。
- 并排与局部对照只裁剪和拼接，不缩放任何比较面板。

## 样板规格

| 对象 | 100% 下的逻辑值 |
| --- | --- |
| 提交标题 / 元数据 | 14 / 11.5 pt，Light |
| Review 标题 / 统计 | 15.5 / 12 pt，Light |
| 文件名 / 路径 | 13.5 / 11.5 pt，Light |
| 代码 / 代码行高 | Menlo 13 pt / 20 pt |
| 提交行 / 顶栏 | 56 / 56 pt |
| 文件头 / hunk 标题条 | 52 / 24 pt |

提交的作者、分支和时间保持次级显示。文件级操作集中在文件头；hunk 标题用接近白色的
背景，减少长 diff 中反复出现的粗灰条。`states.png` 展示普通、hover、选中和禁用外观。

## 生成

先将截图保存到本地，再只读采集与截图相同的 Git 提交：

```sh
python3 Design/Review/capture-fixture.py /absolute/path/to/repository COMMIT Design/Review/output/fixture.json
bash Design/Review/render.sh
python3 Design/Review/compose.py /absolute/path/to/current-screenshot.png
```

`comparison.png` 为整体同尺寸对照，`detail-comparison.png` 为提交列表与前两个文件的局部
对照，`proposal-in-window.png` 将原生样板放回原窗口。`review.html` 内嵌全部图片，可离线
并排、同步滚动或调整叠图透明度。`measurements.json` 记录尺寸、缩放、字体和内容核对结果。

这是一份静态原生样板。按钮用于外观评审；Git 操作、实际 hover 动画和滚动交互在接入
主应用时验证。
