# 滚动截图重新设计方案（窗口捕获 + 手动滚动）

## 现状诊断（为什么不可用）

经深入阅读代码，定位到 5 个根因：

1. **整屏光栅化**：每次轮询都 `capture(rect:)` → 实际捕获**整块 Retina 显示屏再裁剪**（`ScreenshotCaptureService.swift:228-273`），0.18s 一次，CPU/内存压力大。
2. **`isBusy` 丢帧**：捕获在途时 `sampleTick` 直接 `return`（`ScrollingCaptureSession.swift:165`），快速滚过的内容**永远丢失** → 缺行/错位。
3. **弱指纹**：只用**单根中心列**做 FNV 哈希（`:349-374`），居中/重复内容误判为"已到底/空闲"。
4. **硬切缝 + 4px 步进**：拼缝无羽化/无融合（`ScrollingImageStitcher.swift:206-207`），匹配器粗步进 4px 无子像素细化 → 子像素滚动必出可见接缝；验证带无容差 → 频繁误 `tooFast`。
5. **chrome 检测易失效**：仅当参考帧宽度/高度**严格相等**才启用（`:59-61`），否则粘性栏每个缝都重复拼进去（= 用户说的"同帖重复多遍"）。每缝还重分配整画布 ARGB context（最高 ~100MB）→ 崩溃风险。

## 总体策略

用户已选定：**窗口捕获 + 手动滚动**。核心改动是把"定时整屏截图"换成 **SCStream 按窗口连续流**，并据此重写会话、拼接器与面板。

---

## 一、新增 `ScrollingCaptureStream.swift`（SCStream 连续捕获）

新建一个 `@available(macOS 14.0, *)` 类，封装一条**按目标窗口**的连续视频流：

- `SCContentFilter(desktopIndependentWindow: window)` 锁定窗口（复用现有 `ScreenshotCaptureService.captureWindow` 的窗口解析逻辑）。
- `SCStream` + `SCStreamDelegate`，队列 `CFStreamDispatchQueue`，`minimumFrameInterval` ≈ 80–100ms，`showsCursor = false`，`captureResolution = .best`。
- delegate 把每一帧 `sampleBuffer` 转 `CGImage`，**回调时机**：每帧只做"是否运动 / 是否停稳"判定，**不**每帧拼接。
- 暴露：`start(windowID:completion:)`、`stop()`、`onFrame: ((CGImage) -> Void)?`。
- 失败回退：若 `SCStream` 初始化失败/不可用，**降级**为旧的定时 `ScreenshotCaptureService.capture(rect:)` 路径（保留一个开关，确保可用性）。
- **重要**：窗口缩放/移动期间丢弃帧（用 `windowBounds` 比对），避免捕获到变形中间态。

## 二、重写 `ScrollingCaptureSession.swift`

改为**事件驱动 + 帧环缓冲**模型，彻底取消 `isBusy` 丢帧：

### 状态机
- `idle`(首帧未到) → `live`(流中，累积帧) → `merging`(拼接中) → `done`/`cancelled`。
- 取消 `sampleTimer`、`settleWorkItem` 的轮询+延时双时钟；改用**帧间静止检测**：连续 N 帧（如 6 帧 ≈ 0.5s）指纹不变 ⇒ 判为"停稳"，触发一次拼接。

### 帧环缓冲（Ring Buffer）
- 保留最近 ~20 帧原始 CGImage（低成本：只缓存 CGImage 引用，IOSurface 由系统管理）。
- 停稳时：从环里**回挑**与画布底部相关性最高的一帧拼接，而不是只能用"当前帧"。这样即便用户停得不在最佳重叠位，也能找回最佳对齐帧。

### 健壮指纹（替换中心列哈希）
- 改为**多带平均哈希**：取图像上中下 3 条横带的灰度均值，组成一个稳定指纹。停稳判定用这个；拼接相关性仍由 NCC 决定。
- 灰度带从 SCStream 帧直接拿（已 raster），避免 `fingerprint` 里再分配 `w*h*4` 大缓冲。

### 拼接调用
- 停稳时调用新 `ScrollingImageStitcher.stitch(...)`（见下）。
- 成功 `.appended`：把环缓冲清空（保留最后 1 帧作为下一轮基线），刷新预览。
- `.tooFast`：**不再要求用户"往回滚"**——而是自动从环缓冲里换一帧重试；若仍失败才提示"继续滚动一点"。
- `.duplicate` ×2 / `.reachedLimit` / `.failed`：沿用现有语义。

### 捕获目标的确定
会话构造改为接收 `windowID: CGWindowID` + 初始内容子矩形（可选，用于剔除标题栏/工具栏），不再依赖一个固定的屏幕 `selectionRect`：
- 第一帧由 `SCStream` 给出整个窗口；内容子矩形由后续 chrome 检测或用户微调决定（默认全窗）。

## 三、重写 `ScrollingImageStitcher.swift`

保留"画布底模板 → 入帧搜索偏移 → 只追加新内容"的整体思路，但修掉所有脆弱点：

### 匹配精度
- **金字塔层数 3 级**（当前只有粗 stride-4 + 两轮 ±4/±2 微调）。每级 ×2 下采样，最粗层 8 倍。
- **子像素抛物线拟合**：在整数最佳峰 ±2 范围，用 NCC 分数做三点抛物线拟合得亚像素偏移，把画布按该偏移再合成 → 消除可见接缝（解决"拼接不对"）。
- 验证带加 **±2px 容差窗口**（当前无容差，频繁误 `tooFast`）。

### chrome（粘性栏）检测——稳健化
- **不**依赖参考帧严格相等：改用**窗口内固定偏移**模型。会话开始时让用户/自动识别内容区（首帧 + 用户可选微调），记录 `header/footer` 像素高度；之后每次裁掉这两段再匹配。
- 移除"参考帧宽高必须严格相等否则关闭 chrome"的隐患。

### 接缝——羽化融合替代硬切
- 合成阶段改为**接缝带线性 alpha 渐变**（约 6–10px 重叠区做 `dst*（1-a）+ src*a`），消除硬边/亮度突变。
- 不再用"重分配整画布 ARGB context"：改为**只追加**——维护一个可增长的纵向缓冲（`CGContext` 按预估上限一次性分配，或分块拼接），峰值内存显著下降。

### 阈值收敛
- 把所有 magic number 集中到顶部一组 `let` 并注释依据；`minNCC`、`minPeakMargin`、`canvasDupNCC` 根据新匹配器重新标定（预期可放宽，因匹配更准）。
- `maxPixelHeight` 仍用 `ScreenshotChrome.scrollingMaxPixelHeight`（16384）。

### 重复内容检测
- 保留 `appendAlreadyOnCanvas`，但把采样步长收紧到每 ~6px（当前 `appendHeight/36` 近退化），让"同帖重复"判定可靠。

## 四、重写 `ScrollingCaptureOverviewPanel.swift`

让预览**真正反映长截图**：

- 面板**自适应高度**：预览 imageView 高度随画布宽高比增长（夹在 160–360px 之间），不再是固定 196×160 的"细缝"。
- 加一个**进度条/高度刻度**，显示已拼接高度 vs 上限。
- 状态文案保留（moving / stitched / tooFast / end / limit）；新增"已捕获 N 帧"小提示。
- 按钮：Cancel / Done 保留；新增 **Retry**（tooFast 时显式从环缓冲重挑帧）。键位沿用 Esc/Enter/Space。

## 五、改 `CaptureOverlayWindow.swift` 的入口流程

当前 scrolling 模式走的是和 region 一样的"拖拽矩形"。改为**窗口点选**：

- 滚动模式下，`mouseMoved` 复用 `UIElementDetector.detect` + `highlightedBounds`/`highlightedWindowID` 做窗口高亮（代码已存在，`CaptureOverlayWindow.swift:940-951`）。
- 单击窗口（`leftMouseUp` 且无拖拽）→ `submit(.scrollingWindow(windowID, rect))`（新增一个 request case）。
- 仍允许**拖拽矩形**作为高级用法（截窗口局部），此时 fallback 到旧的 `rect` 路径 + SCStream `sourceRect`。
- 进入 scrolling phase 后保留现有"选区鼠标穿透"（`hitTest` 返回 nil，`:634-639`），让用户能滚动底层窗口；但**降低全屏遮罩透明度**（0.45 → 0.12 左右）以免遮挡内容。

`CaptureOverlayController.beginScrollingSession` 改为按 `windowID`（或 rect）创建新会话；`ScreenshotCoordinator` 无需改动。

## 六、日志与崩溃防护（沿用现有基建）

- 所有关键点继续 `appLog(...)`：流启停、停稳触发、拼接 outcome（含 conf）、环缓冲命中、降级 fallback。
- 加一个 `LogLevel.debug` 的详细路径（LogManager 已有 `.debug` 但无人用）——环缓冲/帧指纹用 `.debug`，避免污染常规日志。
- 保持 `AppFont.textAttributes` 安全路径（DesignTokens.swift 未提交的修复）确保面板不再因 monospaced 字体 nil 崩溃；面板里 `monospacedDigitSystemFont` 调用改走 `AppFont`。

## 七、文件改动清单

| 文件 | 动作 |
|---|---|
| `clipy_macos/Sources/ScrollingCaptureStream.swift` | **新建** SCStream 连续捕获封装 |
| `clipy_macos/Sources/ScrollingCaptureSession.swift` | **重写** 事件驱动 + 环缓冲 + 多带指纹 |
| `clipy_macos/Sources/ScrollingImageStitcher.swift` | **重写** 3 级金字塔 + 子像素 + 羽化接缝 + 稳健 chrome |
| `clipy_macos/Sources/ScrollingCaptureOverviewPanel.swift` | **重写** 自适应高度预览 + 进度 |
| `clipy_macos/Sources/CaptureOverlayWindow.swift` | **改** scrolling 模式走窗口点选；遮罩降透明 |
| `clipy_macos/Sources/Localization.swift` | 新增/调整滚动相关文案（含 Retry、窗口点选提示） |
| `build_macos_app.sh` | `SWIFT_SOURCES` 数组里追加 `ScrollingCaptureStream.swift` |

不动：`ScreenshotCoordinator`、`ScreenshotCaptureService`（仅复用其窗口解析与坐标工具）、`DesignTokens`（沿用 `scrollingMaxPixelHeight`）、`LogManager`。

## 八、验收标准（实施后自测）

1. 点选一个长网页/文档窗口 → 滚动 → 停稳即自动拼接，预览随高度增长。
2. 快速滚动**不丢内容**（环缓冲回挑帧）。
3. 含粘性顶/底栏的页面，缝处**不出现重复工具栏**。
4. 接缝**无明显错位/亮带**（子像素 + 羽化）。
5. 长截图超过数千像素仍稳定，无 OOM 崩溃（峰值内存可控）。
6. Esc 取消、Enter 完成、Space 强制采帧 均生效；结果走现有导出管线（剪贴板/保存/编辑器/Pin）。
7. SCStream 不可用时自动降级到旧的整屏截取路径，功能仍可用。

> 说明：此方案聚焦 macOS 端。Android/Flutter 侧的长截图不涉及（Flutter 端无此功能）。
