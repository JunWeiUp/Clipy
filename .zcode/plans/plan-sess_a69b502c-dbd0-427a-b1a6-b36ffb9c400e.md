# Phase 8 收尾计划（验证已通过，仅剩清理 + 文档）

## 状态
所有功能验证通过。删除旧截图文件的代码改动**已部分执行**（7 个旧文件已 `git rm`，构建脚本已移除对应条目，`bash build_macos_app.sh` 重建 EXIT 0 干净）。剩余仅文档更新，因当前会话进入 plan mode（只读）无法继续编辑。

## 已完成（本轮）
- `git rm` 7 个旧截图文件（形成闭环、外部无引用）：
  - `CaptureOverlayWindow.swift` / `CaptureSelectionToolbar.swift` / `CaptureAnnotationPanel.swift`
  - `ScreenshotCoordinator.swift` / `ScreenshotEditorViewModel.swift`
  - `UI/ScreenshotToolbarView.swift` / `UI/AnnotationCanvasView.swift`
- `build_macos_app.sh`：从 `SWIFT_SOURCES` 移除上述 7 条；Info.plist 已加 `NSMicrophoneUsageDescription` + `NSCameraUsageDescription`
- 重建验证：`EXIT 0`，删除后整包仍干净编译

## 待完成（需退出 plan mode 后执行）
1. **更新 `AGENTS.md`** 架构段：
   - 「总览」的截图一行改为描述新的 macshot 移植模块（统一 OverlayView、18 工具、滚动/录屏/美化/OCR/翻译、贴图/缩略图/编辑器、中文本地化）
   - 「macOS 端结构」把已删文件（ScreenshotCoordinator/ScreenshotEditorViewModel 等）的条目移除，新增 `Sources/Screenshot/` 目录说明（Capture/Model/Services/UI 全套 + `ScreenshotSessionCoordinator.swift` + `ScreenshotRecorders.swift` + `FloatingThumbnailPresenter.swift` + `Services/L.swift`/`ScreenshotLocalization.swift`/`ScreenshotSounds.swift`/`ScreenshotAppIntegration.swift` 等适配层）
   - 「对话记录」追加本次会话：照 macshot 重做截图全功能 + 中文 + 滚动/录屏/缩略图 + 删旧文件
2. **更新 `README`**（如截图功能段落需要同步新能力）
3. 不做 git commit（除非你明确要求）

## 风险
- 纯文档改动，零代码风险。文件删除已验证不破坏构建。

## 我需要做的
确认后我直接更新 AGENTS.md（架构段 + 对话记录）和 README 截图段落，完成 Phase 8。