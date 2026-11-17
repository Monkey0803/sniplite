# Phase 0 技术验证结果（SCK / 覆盖窗 / 剪贴板）

机器：macOS 27.2 (26B123)，Apple Silicon（arm64），Xcode 27.3。
验证程序：[spike.m](spike.m)（`./build.sh` 后 `open -n build/SnipliteSpike.app --args --mode all`），
结论来自它写出的 JSON 报告与截图，`--mode info|capture|overlay|paste` 可单独重跑。

## 1. 截屏（ScreenCaptureKit）

| 问题 | 结果 |
| --- | --- |
| 能否拿到每块屏的原生像素尺寸 | 能。按 `SCDisplay` 的 points × `backingScaleFactor` 设 `SCStreamConfiguration.width/height`，返回的 `CGImage` 尺寸与预期**完全一致** |
| 多屏 | 能，2 块屏（主屏 2560×1440、副屏 1920×1080，均在 1x）各自一张 |
| 一次调用截整个虚拟屏 | 能。macOS 15.2+ 的 `+[SCScreenshotManager captureImageInRect:]` 直接给了 4480×1440 的合并图，跨屏坐标正确 |
| 冷/热延迟 | 首屏 2560×1440 首次调用 **243 ms**（含 SCK 初始化），第二次 1920×1080 仅 **45 ms**；合并图首次调用 167 ms |
| 内容是否真实 | 是：截到完整桌面（菜单栏、ChatGPT 窗口、Dock），非黑屏 |
| 权限 | 验证进程 `CGPreflightScreenCaptureAccess()` 为 true（继承了启动它的宿主进程的授权）；全新 ad-hoc app 的首次授权流程留到 Phase 2 实测 |

结论/对方案的影响：
- **启动时预热一次 SCK**（先 `getShareableContent` 再空截一张），把 243 ms 的初始化挪出热键路径；热键到冻结帧目标仍是 ~150 ms 以内。
- 冻结帧优先用 `captureImageInRect`（一次调用、跨屏、坐标即 points），拿不到时回退逐屏 `SCContentFilter`。长截图采样同样用它。
- 本机两块屏都是 1x，**Retina 2x 未实测**；换算逻辑（points × scale = 像素）已用 1x 对齐验证，Phase 2 在有 2x 屏时补一次校验（同一套代码，风险低）。

## 2. 覆盖窗能否盖住菜单栏

`NSWindow` 设为 borderless、`level = CGShieldingWindowLevel()`（本机 2147483628）、
`collectionBehavior = canJoinAllSpaces | stationary | fullScreenAuxiliary`，每屏一个窗。

- 用「截屏后读像素」验证而不是肉眼：菜单栏高度内（y=10pt）读到 `#FF00FF`（覆盖层条带色），
  条带下方的像素是压暗后的桌面（`#2E3031`）。→ **覆盖菜单栏成立**。
- 证据图：`/tmp/sniplite-spike/overlay-proof.png`（顶部洋红条带盖住了整个菜单栏）。
- 遮罩窗不在自己的截图里：先冻结帧、后显示覆盖窗即可（Windows 版同一思路）。

## 3. 剪贴板 PNG

`NSPasteboard.general` 写入 `public.png` 后读回：字节数、解码后像素均一致；
系统同时登记了 `public.tiff`。→ Phase 4 直接用 `NSPasteboard` + ImageIO 即可，无需自写编码器。

## 结论

三项 hard gate 全部通过，按方案继续 Phase 1。记录一条对实现的修正：**用 `captureImageInRect`
作为主截屏路径**（比逐屏 filter 少一次 COM 往返，且天然多屏），逐屏 filter 只作 15.2 以下的回退。
