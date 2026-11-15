> **实验品 / EXPERIMENTAL — 已暂停**
>
> 当前正式 macOS 客户端继续使用 `../clipy_macos/`（Swift/AppKit）。本目录仅保留 NSH/TSX 技术验证源码与独立构建脚本，不参与默认构建、发布或正式数据迁移。未经用户明确要求，不恢复实验、不替换正式应用。生成产物与专用缓存已清理，重新验证时按本目录脚本重建。

# Clipy macOS — NSH/TSX 实验品（已暂停）

A fresh implementation of Clipy's V3 macOS design, using **NSH 0.5.0's prebuilt runtime**, TypeScript/TSX, and a small Swift system helper. There is no Cargo project and no project-local Rust build directory. The maintained production client is unchanged.

Only run the following commands after an explicit decision to resume the experiment.

```sh
nsh check clipy_macos_nsh_experimental
nsh test clipy_macos_nsh_experimental
./clipy_macos_nsh_experimental/scripts/run_macos.sh
./clipy_macos_nsh_experimental/scripts/package_macos.sh
```

Requires macOS 14 or later. Run from the repository root. Install the official NSH 0.5.0 CLI and Xcode command-line tools first. SwiftPM resolves the Common Relay Swift SDK from the sibling `common-relay` repository; set `COMMON_RELAY_PATH` to its `sdk/swift` directory when using another layout. Generated Swift builds and preview app packages live in the user's cache directory (`CLIPY_NSH_CACHE` overrides it), outside the source tree. TSX changes only rebundle the app; Swift changes rebuild the helper. `package_macos.sh` creates an **isolated preview**, not a production installation. It uses an ad-hoc signature unless `CLIPY_NSH_SIGN_IDENTITY` supplies a stable certificate. Local installation must retain the existing preview certificate and designated requirement across its launcher, runtime and helper, so macOS permissions keep their app identity. Do not use the preview to replace the production app.

Set `CLIPY_NSH_BIN` to select the pinned 0.5.0 executable if several NSH versions are installed. A package records its source hashes under `Resources/nsh/source-inputs.json`.

The main window can be reopened from its menu-bar icon. The preview's temporary global history shortcut is Control+Option+Command+F, avoiding the installed client's shortcuts. Closing the window keeps the menu-bar app running; the application menu explicitly quits it.

## Implementation

- `App.tsx`: lifecycle and native entry.
- `src/app/`: desktop windows/menus and feature integration.
- `src/core/`: persistent data, validation, history/snippets/notifications/words and cancellable dictionary lookup.
- `src/screens/`, `src/ui/`: macOS pages and semantic controls.
- `src/editor/`: annotation scene and interactive image canvas.
- `src/native/`: bounded private stdio RPC transport.
- `host/macos/`: Swift system, capture, media, LAN and Common Relay integration.
- `scripts/`: cache-aware native build, development launch and preview package.

The Swift launcher sets up the helper's executable path inside the preview bundle, then executes NSH's prebuilt runner. The runtime owns the private helper's process lifetime. Requests have correlation IDs and timeouts; media uses file paths rather than JavaScript base64 buffers. LAN reception is acknowledged after application persistence succeeds. No production history, keys or identity are imported automatically.

## Validation status

This experiment is paused. The following validation notes describe the historical prototype. Type checking, headless feature regressions, private native-service tests and actual-window checks are separate gates. Visible controls do not establish that a system feature passed real-device verification. Unavailable capabilities report errors or are explicitly disabled while implementation continues. The local project documentation records the complete feature matrix and current acceptance evidence. No public release or replacement installation is implied by a successful preview build.

## 与原 Mac 工程的目录边界

- `clipy_macos_nsh_experimental/`：本次全新实现，NSH 预编译运行时、TSX、Swift helper。
- `clipy_macos/`：原 Swift/AppKit Mac 工程，继续保留。

两者是同一 Git 仓库中的平级目录；新工程独立保存入口、资源和构建脚本，不引用原工程源码或图标路径。公网 SDK 仅从 common-relay 接入。新预览安装名为 `Clipy TSX Preview.app`，原安装为 `ClipyClone.app`。

## Screenshot editor

Capture selection supports resize handles, exact sizes/aspect ratios, window snapping and direct output actions. The TSX annotation layer keeps the selected screen coordinates; the independent editor provides a horizontal toolbar, inspector and final-output actions. Custom colors/gradients, image stamps, screenshot composition and editable inline translations share the native render contract. Draft originals are not added to history before editing; successful final outputs are committed explicitly.

Default on-device translation requires **macOS 26+ and installed source/target language packs**. Missing packs show download guidance. Online model translation requires explicit selection and configuration; a failed system translation never falls back to sending text externally. The client itself still runs on macOS 14+. Recognition models run in short-lived bounded child processes.
