# sniplite for macOS

Windows 版 sniplite 的**原生 macOS 移植**（不是 Wine 包装）：保留 `src/` 里可移植的 C
（语言表、配置、热键语法、矩形/字符串工具，以及长截图的拼接算法与 OCR 流程），把平台层换成
AppKit + CoreGraphics + ScreenCaptureKit + ImageIO。Windows 构建（`build.bat`、`src/*.S`）保持原样。

开发细节、模块清单与设计取舍见 [mac/README.md](mac/README.md)。

## 构建与安装

逐条 DoD 与验收步骤见 [mac/DOD.md](mac/DOD.md)。

要求：Apple Silicon、macOS 14 或更新、Xcode 命令行工具。

```sh
./mac/build.sh
cp -R build/sniplite.app /Applications/
```

ad-hoc 签名；要稳定「屏幕录制」授权可 `SIGN_ID="sniplite dev" ./mac/build.sh`。
首次截图需在「系统设置 → 隐私与安全性 → 屏幕录制」允许 sniplite；弹窗里有「重新启动 sniplite」
按钮，点它即可让新授权生效（macOS 只在进程启动时应用屏幕录制权限）。

## 用法

| 操作 | 快捷键 |
| --- | --- |
| 采集 | `⌃⌥1`（菜单栏菜单亦可） |
| 贴图 / 贴剪贴板 | `⌃⌥2` |
| 隐藏/显示全部贴图 | `⌃⌥⇧2` |
| 复制选区 | `Enter` / `⌘C` |
| 另存 PNG/JPEG（默认名带时间戳） | `⌘S` |
| 贴图当前选区 | `⌘T` 或鼠标中键 |
| 长截图 | 工具栏「长截图」或 `⌘L` |
| 撤销/重做 / 删除标注 | `⌘Z` / `⇧⌘Z` / `⌫` |
| 工具快捷键 | `1`–`9` |
| 取消 / 取消选区 | `Esc` |

选区阶段：悬停高亮窗口、滚轮切换窗口、拖拽框选、单击选窗口、放大镜显示像素与坐标。
编辑阶段：九个工具（矩形/椭圆/直线/箭头/画笔/马克笔/马赛克/文字/序号）、8 色、3 档粗细、
撤销重做、八手柄缩放与拖动移动、文字用内嵌输入框（支持中文输入法）。
贴图：拖动、滚轮缩放、`⌘`+滚轮透明度、双击/`Esc` 关闭、右键菜单、全部隐藏。
长截图：选区外细边框 + 控制条 + 拼接预览条；自己滚动页面，`Enter` 复制、`Esc` 取消。
设置：状态栏菜单 →「设置…」，四页（常规/截图/快捷键/关于），改动立即生效。

配置：`~/Library/Application Support/sniplite/sniplite.ini`（INI 格式与 Windows 版相同）。
日志：`~/Library/Logs/sniplite.log`。

## 与 Windows 版的差异

- 默认热键改为 `⌃⌥1` / `⌃⌥2` / `⌃⌥⇧2`（F1/F3 在 macOS 上是系统键），可在设置里改。
- 没有 Dock 图标，只有菜单栏图标；没有安装器、自动更新、命令行客户端、OCR 与表格识别。
- 选区限制在拖拽开始的那块屏（每屏一个覆盖窗）；长截图从第一帧采样处开始拼接。
- 体积约 700 KB（Windows 版 280 KB）；截图延迟约 70–250 ms（Windows 版宣称 12 ms）。
- 覆盖层键盘（`Enter`/`Esc`）依赖 app 取得焦点；从访达/应用程序启动正常，从终端直跑可能被系统拒绝激活。

## 测试

```sh
./mac/build.sh test       # 79 项：热键/键码映射/重复检测/配置/矩形/字符串/语言/Img
./mac/build.sh captest    # 8 项：截屏行序、多屏 tile、粘贴板（需屏幕录制权限）
./mac/build.sh annotest   # 40 项：标注渲染与翻转、Retina 2x/混合缩放裁切、撤销历史、保存 PNG/JPEG、粘贴板
./mac/build.sh pintest    # 13 项：贴图位置、隐藏/显示、实际绘制、剪贴板贴图
./mac/build.sh stitchtest # 9 项：滚动拼接（合成页面、逐行校验）
./mac/build.sh longtest   # 9 项：长截图端到端（需屏幕录制权限）
./mac/build.sh uitest     # 43 项：覆盖层交互（拖选/手柄/微调/移动/调色板/文字/撤销/复制/Esc）+ 贴图创建与缩放
./mac/build.sh uitest-app # 46 项：同上，但由 open 启动，校验激活与键盘焦点
```

## 验收状态

自动化部分全部通过（246 项）：覆盖层的拖选/八手柄缩放/方向键微调/移动选区/工具栏/调色板颜色/
文字工具/撤销重做/复制/Esc、贴图创建与缩放、标注另存 PNG/JPEG，从访达启动时的 app 激活与键盘
焦点（`active=1 keyWindow=1 firstResponder=SnipOverlayView`，带 1s 重试），100 个标注重绘 11.3 ms。
仍依赖真实输入与系统授权的条目（全局热键手感、真实鼠标拖拽、屏幕录制授权流程、中文输入法）
需要在授权后的 app 上人工走查。
