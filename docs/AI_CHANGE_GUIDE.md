# Change guide for coding agents

This is the shortest route from a request to the code that owns it. Read
[ARCHITECTURE.md](ARCHITECTURE.md) for the runtime picture, the relevant design
standard before changing UI, and [PROTOCOL.md](PROTOCOL.md) before changing sync.
The source is authoritative when a guide and implementation disagree.

## Find the owner before editing

| Request area | Start here | Boundary to preserve | Focused check |
| --- | --- | --- | --- |
| Menu-bar click, classic menu, action routing | `clipy_macos/Sources/App/MenuController.swift` | Left click is the nonactivating panel; right click is `NSMenu`. Do not rebuild a tracked menu. | `MenuBarPanelRegression`, native menu smoke |
| Compact panel layout and search | `Sources/MenuBarPanel/` | `MenuBarPanelController` owns show/dismiss/focus; `Model` owns transient state; `View` renders it. Clear results and monitors on dismiss. | `MenuBarPanelRegression`, light/dark snapshots |
| Hidden menu-bar icons | `Sources/MenuBarOverflow/` | AX scan, image capture and AXPress have separate phases. Stale identity or an unconfirmed press must not trigger a guessed click. | `MenuBarOverflowRegression`, opt-in live tests |
| Clipboard and history | `Sources/Clipboard/`, `Sources/History/` | `ClipboardManager` orchestrates; repositories own SQL; media paths live in `HistoryMediaStore`. Search pages and cancellations precede UI display. | search/history regressions |
| Snippets and hotkeys | `Sources/Snippets/`, `App/HotKeyManager.swift` | Persist snippets through `SnippetManager`; unregister keys before reuse. | core regressions, keyboard check |
| Screenshot, pin, recording | `Sources/NativeScreenshot/`, `App/ScreenshotImageProcessor.swift` | `NativeScreenshotCoordinator` owns the session; capture/overlay/editor own temporary images and monitors. | native screenshot regressions, live flow and settled footprint |
| Token usage | `Sources/TokenUsage/` | Sources parse metadata; store owns SQLite/cursors; manager scans only on open/refresh; view prices from catalog. Do not persist prompts or sync usage. | `TokenUsageRegression`, empty/unpriced UI |
| Notifications | `Sources/Notifications/`, `UI/NotificationView.swift` | Repository persists; manager routes; view model pages and clears data on close. | notification UI and sync checks |
| Sync | `Sources/Sync/`, `clipy_android/lib/sync/` | Wire changes require both implementations and `PROTOCOL.md`. Persist remote history before ACK. | socket/protocol tests on both sides |
| Android startup and background work | `clipy_android/lib/app/`, `android/app/src/main/` | One Flutter engine; channels belong to `Application`, not the visible Activity. FGS types must match the manifest. | Flutter tests, Android build/device checks |
| Android screens | `clipy_android/lib/features/`, `lib/ui/` | Features own page state; repositories own persistence; follow `ANDROID_DESIGN.md`. | `scripts/check.sh flutter` |
| Windows desktop system integration | `clipy_android/windows/runner/`, `lib/clipboard_manager.dart` | C++ owns clipboard, screenshot selection, tray and system paths; Dart owns durable history and sync. | Windows CI build, ZIP extraction and real desktop screenshot smoke |
| iOS app integration | `clipy_android/ios/Runner/`, `lib/app/bootstrap.dart`, `lib/storage_paths.dart` | User-initiated paste only; foreground sync lifecycle; no Android listener calls. | unsigned iOS build, simulator launch and device permission check |

`Sources/` in macOS rows means `clipy_macos/Sources/`. `build_macos_app.sh`
collects Swift files recursively, so adding a source file needs no project-file edit.
The independent screenshot module uses small capture, annotation, recording,
recognition, editor and delivery components. Keep a change in its owning component
and retain the one-session boundary in `NativeScreenshotCoordinator`.

For a screenshot change, follow this chain instead of editing the overlay first:

| Step | Owner |
| --- | --- |
| Screen/window/frame acquisition and long capture | `NativeScreenshot/Capture/` |
| Session, focus return, history and recording handoff | `NativeScreenshot/Coordinator/` |
| Annotation data, geometry and rendering | `NativeScreenshot/Annotation/` |
| Selection and editor controls | `NativeScreenshot/UI/` |
| OCR, QR, redaction and translation | `NativeScreenshot/Recognition/` |
| Image transforms, formats, pins and thumbnails | `NativeScreenshot/Editor/`, `Encoding/`, `Delivery/` |
| MP4/GIF, audio, camera and input overlays | `NativeScreenshot/Recording/` |

## Follow the data and lifetime

```text
macOS: status item → MenuController → panel/model or feature window
       clipboard → ClipboardManager → HistoryRepository → AppDatabase
       screenshot → NativeScreenshotCoordinator → delivery → clipboard/history
       local Agent logs → TokenUsageSource → TokenUsageStore → report/pricing → UI

Android: Application → one FlutterEngine → platform channels → managers/repositories
         sync discovery/session → protocol/crypto → persistent inbound store → ACK
```

- `AppDelegate` starts long-lived services. Feature windows use `WindowSession`;
  their close hook must cancel work and release large view-model data. A cached
  window is retained for up to five minutes for reopen and later loses its
  hosting view.
- `MenuBarPanelController` owns its event monitors and dismisses before handing
  off focus. `MenuController` creates it on first use; closed-menu data callbacks
  must not initialize it. `MenuBarOverflowManager` keeps a metadata snapshot while idle;
  its periodic AX refresh and image capture belong to a visible panel/menu only.
- Screenshot overlays, CI contexts, images and recording buffers are temporary.
  Keep their release path paired with capture teardown. Do not reclaim while a
  visible panel/window still owns the content.
- Token and model-price data stay local to macOS. No Android or LAN schema change
  is needed for a Token UI request.

## Make a change safely

1. Identify one owner in the table; use `rg` to trace its call site and storage
   boundary. Check the working tree before edits and keep unrelated changes.
2. Change the smallest vertical slice: model or parser, repository if storage
   changes, controller for lifecycle, then view and localized strings. If an
   interface crosses macOS/Android, update both ends together.
3. For new long-lived work, name its start, cancellation and release paths.
   Bound queues, caches, page sizes, timers and file reads. Do not make a menu
   open spawn permanent polling or retain full history/media in a singleton.
4. Update the relevant architecture/design/protocol document when the owner,
   flow or contract changes. Keep English and Chinese README feature claims in
   sync with actual source behavior.
5. Run the smallest meaningful regression, then the required repository gate.
   Expand testing only for a concrete remaining risk. Inspect the real UI for
   visible macOS layout changes.

## Verification map

| Change | Minimum check |
| --- | --- |
| macOS model, window, menu or lifecycle | `bash scripts/test_macos_core.sh`, `bash scripts/check.sh repo`, `git diff --check`, macOS build |
| Native UI layout | Above plus light/dark, empty, long-content and accessibility-label inspection |
| Android-only feature | `bash scripts/check.sh flutter` and relevant device/emulator flow |
| Sync protocol/storage | macOS core tests, Flutter tests, `docs/PROTOCOL.md`, bidirectional device flow |
| Signing/install | Use the host's configured stable-signature procedure; verify requirement and actual process path after install |

For memory claims, compare the **physical footprint** under the same scenario,
after the same settling interval. `ps` RSS includes shared mappings and is not the
same measurement. `/usr/bin/footprint <pid>` reports `phys_footprint`;
`vmmap -summary <pid>` attributes regions. Run repeated open/close or capture cycles
and compare settled values, not only the peak. `leaks` can be incomplete when
the installed process is not debuggable; a clean or small report cannot prove
the absence of every leak. Use Instruments Allocations/Leaks on a debuggable
build when a specific cycle still grows.
