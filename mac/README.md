# sniplite for macOS

验收清单（DoD 逐条对照与人工步骤）见 [DOD.md](DOD.md)。


这是 Windows 版 sniplite 的**原生 macOS 移植**（不是 Wine 包装）：保留 `src/` 里可移植的 C
（语言表、配置、热键语法、矩形/字符串工具，之后还有长截图拼接与 OCR 流程），把平台层换成
AppKit + CoreGraphics + ScreenCaptureKit + ImageIO。

Windows 构建（`build.bat`、`src/*.S`）保持原样，本目录和 `src/` 里少量 `#ifdef __APPLE__`
是移植的全部改动。

## 现状

| 阶段 | 内容 | 状态 |
| --- | --- | --- |
| Phase 0 | SCK 截屏 / 覆盖菜单栏 / 粘贴板 PNG 三项验证 | 完成（见 [spike/FINDINGS.md](spike/FINDINGS.md)） |
| Phase 1 | 骨架：agent + 状态栏 + 全局热键 + 单实例 + 配置/语言 | 完成 |
| Phase 2 | 截屏与选区（冻结帧、覆盖层、框选、窗口识别、放大镜） | 完成 |
| Phase 3 | 标注与工具栏（9 工具、颜色/粗细、撤销重做、文字输入） | 完成 |
| Phase 4 | 复制/保存/贴图（Enter、⌘S、⌘T/中键、剪贴板贴图） | 完成 |
| Phase 5 | 长截图（滚动拼接、边框+控制条+预览条） | 完成 |
| Phase 6 | 偏好设置窗口（常规/截图/快捷键/关于） | 完成 |

现在可以用的完整链路：

1. `⌃⌥1`（或 `--capture`）→ 冻结所有屏幕 → 压暗覆盖层 → 悬停高亮窗口、滚轮换窗口、拖拽框选、
   点击直接选窗口；放大镜显示像素与坐标。
2. 选完后进入编辑：工具栏九个工具（矩形/椭圆/直线/箭头/画笔/马克笔/马赛克/文字/序号）、
   颜色（8 种）与粗细（3 档）、撤销/重做、选区八个手柄与拖动移动；`1`–`9` 快选工具，
   `Esc` 退回选区（再按取消），方向键微调选区（⇧ 10pt），`⌫` 删除最后一个标注。
3. `Enter`/`⌘C` 复制带标注的图，`⌘S` 另存 PNG/JPEG（保存前会先收起覆盖层），`⌘T` 或鼠标中键贴图。
4. 贴图窗口可拖动、滚轮缩放、`⌘`+滚轮调透明度、双击或 `Esc` 关闭、右键菜单（复制/保存/重置/
   置顶/关闭/全部关闭）；`⌃⌥2` 把剪贴板里的图片或文字贴出来，`⌃⌥⇧2` 隐藏/显示全部贴图。

长截图：选区后点工具栏的"长截图"（或 `⌘L`）→ 选区四周出现细边框、下方是控制条
（复制/保存/贴图/关闭），右侧是拼接预览条；滚动页面即可，`Enter` 复制、`Esc` 取消。

设置：状态栏菜单 →「设置…」（或 `--settings`），常规/截图/快捷键/关于四页；快捷键页点击输入框后
按下组合键即生效（与其他动作重复的组合会被拒绝），旁边显示"生效/不可用"；改动立即写入 ini 并重新注册热键。

OCR（文字识别）、自动更新、安装器、命令行客户端不在本次移植范围内。

## 构建与运行

```sh
./mac/build.sh          # 产出 build/sniplite.app（arm64，ad-hoc 签名）
open build/sniplite.app # 启动；没有 Dock 图标，图标在菜单栏右侧
cp -R build/sniplite.app /Applications/   # 想长期用就放这里
```

单元测试（共享 C + 兼容层），以及截图/裁切/剪贴板的端到端自测（自己摆一个上红下蓝的窗口再截图，
校验行序、多屏 tile 和粘贴板像素，不需要人工、不需要热键）：

```sh
./mac/build.sh test      # 79 项：热键/配置/矩形/字符串/语言/Img
./mac/build.sh captest   # 8 项：截屏行序、多屏 tile、粘贴板像素（需要屏幕录制权限）
./mac/build.sh annotest  # 40 项：标注渲染与翻转、Retina 2x/混合缩放裁切、撤销历史、保存（PNG/JPEG）、粘贴板
./mac/build.sh pintest   # 13 项：贴图窗口位置、隐藏/显示、绘制、剪贴板贴图
./mac/build.sh stitchtest # 9 项：滚动拼接（合成页面、逐帧偏移、内容逐行校验）
./mac/build.sh longtest  # 9 项：长截图端到端（自滚动窗口 → 采样 → 拼接 → 粘贴板）
./mac/build.sh uitest    # 43 项：覆盖层交互（拖选/手柄/微调/移动/调色板/文字/撤销/复制/Esc）+ 贴图创建与缩放
./mac/build.sh uitest-app # 46 项：同上，但从访达启动（open），额外校验 app 激活、键盘焦点在覆盖层
```

要求：Apple Silicon、macOS 14 或更新、Xcode 命令行工具（`clang`、`sips`、`iconutil`）。

### 签名与屏幕录制权限

用 ad-hoc 签名（`codesign -s -`）。首次采集时系统会要求「屏幕录制」权限；授权后需要重启一次
app（SCK 的限制）。重建后若系统反复要求授权，用本机自签证书稳定身份：

```sh
SIGN_ID="sniplite dev" ./mac/build.sh
```

（证书在「钥匙串访问 → 证书助理 → 创建证书」里生成，类型选「代码签名」。）

## 与 Windows 版不同的地方

- **默认热键**：F1/F3 在 macOS 上属于系统（亮度、调度中心），所以默认改为
  `⌃⌥1` 采集、`⌃⌥2` 贴图、`⌃⌥⇧2` 隐藏/显示全部贴图；设置里可改成任意组合，
  语法沿用 `Ctrl+Alt+A` / `F1`（`Ctrl/Alt/Shift/Win` 对应 `⌃⌥⇧⌘`）。
- 没有 Dock 图标（`LSUIElement`），只有菜单栏图标。
- 配置在 `~/Library/Application Support/sniplite/sniplite.ini`（INI 格式不变，可从 Windows 版拷过来）。
- 日志在 `~/Library/Logs/sniplite.log`。
- 没有安装器、卸载器、自动更新、命令行客户端；这些在 Windows 版才有。
- 屏幕录制是系统级授权；「低内存模式」在 macOS 上对应逐屏截取。
- 选区**限制在拖拽开始的那块屏**内（每屏一个覆盖窗；跨屏选区留待以后）。
- 覆盖层的键盘（`Enter`/`Esc`）需要 app 拿到焦点。正常从访达/应用程序启动没问题；从终端直接跑
  二进制时 macOS 可能拒绝激活（实测 `isActive=0`），这时鼠标仍可用，右键取消。

## 目录

```
mac/
  build.sh      clang 编译 + 手拼 .app + 签名；`test` 跑单元测试
  Info.plist    LSUIElement、bundle id、最低系统版本
  plat.h        共享 C 需要的 Windows 类型/函数名在 macOS 上的定义
  compat.m      上面这些函数的实现（堆、时钟、UTF-8、INI、文件、日志）
  app.m         agent 生命周期、状态栏与菜单、单实例、占位 HUD
  hotkey.c      Carbon 全局热键（把 VK_* 映射到 macOS key code）
  capture.m     ScreenCaptureKit 冻结帧、多屏 tile、窗口枚举、预热
  overlay.m     覆盖窗、选区、工具栏交互、文字输入、输出动作
  annotate.m    标注模型、撤销历史、标注渲染
  draw_cg.c     Core Graphics 绘制原语 + 图标绘制
  toolbar.c     工具栏/调色板布局、命中测试与绘制
  icons.h       draw_icons.inc 的类型与枚举
  icons_data.c  由 mac/tools/gen_icons.py 生成的图标数据
  output.m      裁切、标注合成、粘贴板、PNG/JPEG 文件
  pin.m         贴图面板（拖动/缩放/透明度/右键菜单/隐藏全部）
  tools/        gen_icons.py
  spike/        Phase 0 验证程序与结论
  tests/        共享 C 的单元测试
```

## 代码复用

直接复用（由 `plat.h`/`compat.m` 提供 Windows 名字）：`src/lang.c` + `src/lang_text.h`、
`src/config.c`、`src/util.c`。

重写为 macOS 平台层：截屏（`src/shot.S`）、覆盖层合成与绘制（`src/present.S`、`src/ov_*.S`）、
剪贴板/编码（`src/image.S`）、常驻与托盘（`src/main.c`）、贴图（`src/pin.c`）、设置
（`src/settings.c`）。汇编热路径改写为 C。

详见根目录 README 与 `mac/spike/FINDINGS.md`。

## 调试开关

构建出的 app 支持几个只在开发时用的参数（`open build/sniplite.app --args <flag>` 或直接运行二进制）：

- `--capture`：启动后立刻触发一次截图（不用热键），调试覆盖层用；
- `--settings`：启动后打开设置窗口；
- `--long`：在固定区域直接进入长截图模式，用来观察边框/控制条/预览条；
- `--pin-demo`：贴一张渐变色贴图，用来观察贴图窗口；
- `--version` / `--help`：版本与用法；
- 环境变量 `SNIPLITE_OVERLAY_DEMO=1|2`：显示覆盖层并自动摆一份示例标注（2 会打开调色板），
  用于截图和视觉回归；
- 测试钩子在 `-DSNIPLITE_TEST` 下编译（`ov_test_*`），产品二进制不含它们。

## 静态检查

```sh
xcrun clang --analyze -fobjc-arc -std=gnu11 -I../src -I. -target arm64-apple-macos14.0 *.m *.c
```

除 `capture.m` 的一处已知误报外无告警：分析器看不到 `dispatch_after` 里的超时清理，会认为
ScreenCaptureKit 不回调时 tile 数组泄漏；实际超时分支会释放 tile 和已到达的帧
（见 `cap_take` 里 `aborted` 的处理）。其余曾在早期版本出现的告警（init 前写 ivar、
`ftell` 失败时 `malloc(0)`、CF 对象所有权不明）已修复。
