# 验收清单（方案第 2 节 DoD）

**验收状态：2026-11-17 由用户在实机确认通过**（屏幕录制授权、真实鼠标/键盘、中文输入法、保存面板/贴图/长截图均已走查）。

这一页把方案里的 DoD 逐条对上实现与证据，方便你自己复核。"自动"一列是仓库里能重跑的命令；
"人工"一列只有在你授权了「屏幕录制」的 app 上才做得了（需要真实鼠标键盘与中文输入法）。

## 环境与构建

```sh
cd sniplite                      # 仓库根目录
./mac/build.sh                          # -> build/sniplite.app（ad-hoc 签名）
cp -R build/sniplite.app /Applications/
open /Applications/sniplite.app         # 不要从终端直跑：系统会拒绝它激活
```

要求：Apple Silicon、macOS 14+、Xcode 命令行工具。

## DoD 对照

| # | 方案要求 | 实现 | 自动证据 | 需要人工确认 |
| - | --- | --- | --- | --- |
| 1 | 热键到冻结画面约 150 ms；多屏各自覆盖；覆盖菜单栏 | `hotkey.c` + `overlay.m`（每屏一个 `CGShieldingWindowLevel` 窗口） | 日志 `overlay up in 68–112 ms`（双屏，含采集 42–65 ms/屏）；`captest` 8 项 | 按 `⌃⌥1` 的手感；两个屏都变暗、菜单栏被遮住 |
| 2 | 悬停高亮窗口、滚轮换窗、拖选、放大镜 | `overlay.m` 选区阶段 | `uitest` 覆盖拖选/边界语义（100→500 为 401px）；放大镜为绘制代码 | 真实悬停/滚轮/放大镜观感 |
| 3 | 工具栏 9 工具、颜色/粗细、撤销重做、八手柄、拖动移动、尺寸标签 | `toolbar.c` + `annotate.m` + `overlay.m` | `uitest` 43 项（含手柄缩放、方向键微调、移动、调色板、文字、撤销重做）；`annotest` 40 项（含 100 标注重绘 10.9 ms） | 真实拖拽手感；中文输入法候选词 |
| 4 | `Enter` 复制带标注 PNG、`⌘S` 另存、`⌘T`/中键贴图、`Esc` 退出 | `output.m` + `overlay.m` | `uitest` 校验粘贴板 PNG 尺寸/像素/标注颜色；`annotest` 校验另存 PNG/JPEG 可解码；`uitest` 校验贴图按钮创建/缩放/层级 | 粘到 Keynote/预览的效果；保存面板；中键贴图 |
| 5 | 贴图拖动、滚轮缩放、`⌘`+滚轮透明度、双击/`Esc` 关闭、右键菜单、`⌃⌥⇧2` 隐藏全部、`⌃⌥2` 贴剪贴板 | `pin.m` | `pintest` 12 项（位置/隐藏/剪贴板文字与图片）；`uitest` 贴图创建与缩放 | 拖动/缩放/透明度/右键菜单的实际观感 |
| 6 | 长截图：选区外细边框+控制条+预览条；滚动拼接；`Enter` 复制、`Esc` 取消 | `longscreen.m` + `stitch.c`（移植 `src/scroll.c`） | `stitchtest` 9 项（合成页面逐行校验）；`longtest` 9 项（自滚动窗口端到端，画布逐行等于源页面，400×396） | 滚一个真实网页的拼接结果 |
| 7 | 设置窗口（页签、快捷键可改、持久化、重启生效） | `settings.m` | `test` 79 项含键码映射与重复检测；界面已截图核对；INI 持久化由 `config.c` 既有测试覆盖 | 改一组快捷键后刷新菜单/实际生效；语言切换 |
| 8 | 未授权时提示、可跳系统设置、授权后重启生效 | `overlay.m` 的 `show_permission_alert`（含「重新启动 sniplite」） | 代码路径；日志 `no screen recording permission yet` | 授权弹窗、点「重新启动」后能截图 |
| 9 | Windows 侧 `build.bat`、`src/*.S` 不变 | 共享代码只在 `#ifdef __APPLE__` 内改动 | `git status --short src/*.S build.bat` 为空；`git diff --stat -- src` 6 文件 59 行 | — |
| 10 | 单元测试 | 8 个测试目标 | 当前 **246 项全绿** | — |

## 一键回归

```sh
for t in test captest annotest pintest stitchtest longtest uitest uitest-app; do
    printf '%-11s ' "$t"; ./mac/build.sh $t 2>&1 | tail -1
done
```

期望（当前）：

```
test 79   captest 8   annotest 40   pintest 12
stitchtest 9   longtest 9   uitest 43   uitest-app 46      合计 246
```

`uitest-app` 用 `open -n` 从访达路径启动测试 bundle，额外验证 `active=1 keyWindow=1
firstResponder=SnipOverlayView`，即键盘能进覆盖层。

## 人工验收步骤

从 `/Applications/sniplite.app` 启动（访达双击，别从终端跑）：

1. 按 `⌃⌥1`：屏幕变暗、鼠标下窗口高亮；滚轮换窗口；拖动框选；放大镜显示像素与坐标。
2. 松手后工具栏出现：九个工具、8 色、3 档粗细、`1`–`9` 切工具、`⌘Z`/`⇧⌘Z`、`⌫`。
3. 拖八个手柄缩放、在选区内拖动移动、方向键微调；尺寸标签跟随。
4. 文字工具点一下，用中文输入法输入并回车；序号工具点一下自增。
5. `Enter` 复制 → 粘到备忘录/预览；`⌘S` 另存；`⌘T` 或中键贴图；`Esc` 退出。
6. 贴图：拖动、滚轮缩放、`⌘`+滚轮调透明度、双击/`Esc` 关闭、右键菜单；`⌃⌥⇧2` 隐藏全部、`⌃⌥2` 贴剪贴板。
7. 选区后点「长截图」（或 `⌘L`），滚动一个网页，`Enter` 复制，检查拼接处无错位/重复。
8. 状态栏「设置…」：改快捷键（故意录一个已用的，应显示"已被占用"）、切语言、切「贴图始终置顶」。
9. 若首次按 `⌃⌥1` 弹授权：打开系统设置允许 sniplite，回到弹窗点「重新启动 sniplite」，再试一次。

全部通过即达 DoD；任何一项不对，把 `~/Library/Logs/sniplite.log` 与现象发回即可定位。
