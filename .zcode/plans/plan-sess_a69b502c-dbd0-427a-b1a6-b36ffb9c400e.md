# Mac 端代码按功能重组目录结构

## 目标
把扁平的 `Sources/`(48 根文件 + 21 个 UI 文件)按功能重组为清晰目录,让 AI 一眼定位。同时把构建脚本从"显式列文件"改成 `find` 自动收集(以后加文件零维护)。

## 关键事实(降低风险)
- Swift 同模块内文件**不需要 import**——移动文件只改 `build_macos_app.sh` 路径,**不影响任何代码逻辑**。
- 改成 `find` 全自动收集后,移动文件连脚本都不用改。
- `Sources/Screenshot/` 子树**已组织好,完全不动**。

## 新目录结构
```
Sources/
├── main.swift                          (留根:应用入口)
├── App/                                (应用基础设施)
│   ├── MenuController, PreferencesManager, Localization, HotKeyManager
│   ├── LaunchAtLoginManager, AccessibilityManager, MemoryFootprintReclaimer
│   ├── WindowSession, LogManager, LogWindow, ShortcutRecorderView
│   ├── SearchGlobalHotKeyManager, SearchWindow
│   ├── ScreenshotPreferences (从 ScreenshotTypes 迁出的 4 个枚举)
│   ├── ScreenshotSettingsWindow, ScreenshotGlobalHotKeyManager
├── Clipboard/   ClipboardManager
├── History/    AppDatabase, SQLiteHelpers, HistoryRepository, HistorySerializer,
│   HistoryQueryBuilder, HistoryMediaStore, HistoryThumbnailCache, HistoryKeychain,
│   HistoryMigrationService, SecureStorageCrypto, ImageDownsampler,
│   HistorySearchIndexManager/Builder/Ranker, HistorySearchStateStore, HistorySearchTypes,
│   ImageOCRService (历史索引 OCR)
├── Snippets/   SnippetManager, SnippetEditorWindow
├── Sync/       SyncManager
├── Notifications/  NotificationManager, NotificationRepository, NotificationWindow
├── Screenshot/      (不动 —— 已组织好的截图/录屏引擎)
└── UI/              (共享 SwiftUI 组件 + 各功能视图,UI/Snippets/ 子目录)
```

## 遗留文件彻底清理(7 个)
新 Screenshot 模块已不用它们,先迁移仍被引用的类型再删:

### 纯死代码,直接删(4 个)
- `ScreenshotCaptureService`、`ScreenshotExport`、`CaptureMagnifierView`、`UIElementDetector`

### 迁移类型再删(3 个)
- **`ScreenshotTypes`** → 把 4 个枚举(ScreenshotCaptureMode/PostCaptureAction/OCRLanguage/Resolution)迁到 `App/ScreenshotPreferences.swift`;CoordinateConverter/ToolbarPlacement 随删
- **`ScreenshotImageProcessor`** → 活跃 helper(bestCGImage/releaseCIContext/EncodedImage/encodeForSave)迁进 `Screenshot/Services/ImageEncoder.swift`(与新模块的 ImageEncoder 合并),改活跃调用方引用,再删
- **`ImageOCRService`** → 保留移到 `History/`,内部 `ScreenshotImageProcessor.bestCGImage` 改 `image.cgImage(forProposedRect:)`,`ScreenshotOCRLanguage` 改引用迁移后位置

## build_macos_app.sh 改造
`SWIFT_SOURCES` 硬编码列表替换为 `find Sources -name '*.swift'` 自动收集(临时目录拷贝、框架列表、`-D OFFLINE`、`-target`、Info.plist 全保留)。

## 执行顺序(每步独立编译验证)
1. `build_macos_app.sh` → `find` 自动收集(文件仍在原位,先验证编译)
2. 迁移类型(ScreenshotTypes 枚举 → App/;ScreenshotImageProcessor helper → ImageEncoder)
3. 改活跃调用方引用新位置
4. `git rm` 7 个遗留文件 → 编译验证
5. `git mv` 保留文件到新目录(App/Clipboard/History/Snippets/Sync/Notifications/UI/Snippets/)
6. 最终编译 + 更新 AGENTS.md 目录结构段

## 风险控制
每步 `swiftc -typecheck` + `bash build_macos_app.sh` 双验证;类型迁移改调用方即可(同模块无 import 问题);全程 git 可回滚。