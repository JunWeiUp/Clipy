# macOS Screenshot Engine (`clipy_macos/Sources/Screenshot/`)

> L1 领域胶囊 · 移植自 macshot，独立负责截图、标注、录屏、滚动长截图、贴图与 OCR/翻译。

## 入口与调用链

1. **会话编排**：`ScreenshotSessionCoordinator.swift`（唯一对外接缝，通过 `ScreenshotAppIntegration` 回调 `ClipboardManager` / `SyncManager`，禁止内部直接耦合 App 其他控制器）。
2. **采集层**：`Capture/ScreenCaptureManager.swift`（多屏并发，SCK 优先 + CGWindowList 回退）、`ScrollCaptureController.swift`、`RecordingEngine.swift`。
3. **画布核心（已按职责拆分）**：
   - `UI/Overlay/OverlayView.swift`：属性、工具 handler 路由、Setup/HitTesting、Drawing、Mouse/Keyboard 事件与协议适配。
   - `UI/Overlay/OverlayView+ImageTransforms.swift`：取色、图像变换、吸附参考线、自动测距、缩放。
   - `UI/Overlay/OverlayView+ToolbarAndIsland.swift`：标注控件、工具条与统一控制岛布局（`CaptureIslandView`）。
   - `UI/Overlay/OverlayView+ActionsAndRecording.swift`：选区缩放、工具栏动作、摄像头/麦克风、标注创建。
   - `UI/Overlay/OverlayView+EditingAndOutput.swift`：复制粘贴、撤销重做、标注缓存、输出与清理。
   - `UI/Overlay/OverlayView+CaptureModeBar.swift`：空闲模式栏与快捷键提示条。
4. **标注与独立窗口**：`Model/Annotation.swift`、`UI/Tools/`、`UI/Toolbar/`、`UI/Editor/`、`UI/Windows/`。

## 必须守住的边界

- **OCR 隔离**：所有文字/二维码/敏感信息识别走 `OCRSubprocess`（`--clipy-ocr-child`），禁止回退进程内 Vision 文字识别。
- **内存释放**：选区遮罩、CIContext、录屏缓冲在确认/取消时立即释放；临时缓存目录仅清 Clipy 自有目录，绝不清理其他应用目录。
- **验证**：改完运行 `swift build --package-path clipy_macos`（增量编译）或 `bash scripts/test_macos_core.sh`。
