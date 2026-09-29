# Architecture and code map

Clipy keeps its Swift/AppKit macOS menu-bar application. The Flutter application
shares UI, history storage and the v2 LAN protocol across Android, Windows and
iOS. Kotlin owns Android background services, the Windows C++ runner owns the
system clipboard and tray, and Swift owns iOS user-initiated paste and sandbox
paths. Platform adapters never replace the shared protocol implementation.

## Repository layout

```text
clipy_macos/
  Sources/main.swift          macOS entrypoint (including OCR child dispatch)
  Sources/App/                app lifecycle, menus, preferences, permissions
  Sources/Clipboard/          clipboard manager and models
  Sources/History/            SQLite, media, search, OCR subprocess
  Sources/Snippets/           snippets, folders and global hotkeys
  Sources/Sync/               discovery, transport, crypto, reliability, files
  Sources/Notifications/      notification storage and system routing
  Sources/MenuBarPanel/       native control panel, asynchronous queries and focus handoff
  Sources/MenuBarOverflow/    hidden status-item discovery, previews and AX actions
  Sources/TokenUsage/         on-demand local agent usage import, pricing and macOS UI
  Sources/NativeScreenshot/   independent capture, annotation, recording and delivery
  Sources/UI/                 shared SwiftUI views and window layouts
  Resources/Info.plist        reviewed bundle/permission metadata template
  Resources/token-prices-*.json  bundled offline model-price snapshot and overrides
clipy_android/
  lib/main.dart              default Dart entrypoint only
  lib/app/                   bootstrap, headless bridge, application root
  lib/features/              devices, history, settings, logs, transfers
  lib/database/              repositories and migrations
  lib/sync/                  protocol, crypto, sessions, discovery, reliability
  lib/ui/                    shared theme, components and history widgets
  android/app/src/main/      Kotlin services, platform channels, timer widget
  windows/runner/            Win32 clipboard, screenshot, tray and system path channels
  ios/Runner/                Swift storage, file and paste-control channels
  test/                      deterministic Flutter/protocol tests
  tool/                      explicitly invoked integration probes
scripts/                     shared build configuration and local checks
docs/                        architecture, development, wire protocol
.github/                     CI, public releases, contribution templates
```

Existing managers, models, localization and notification UI remain directly under
`lib/` to keep their import/API surface stable. Move these by feature in focused
follow-ups with tests; do not mix a protocol rewrite with directory reorganization.

Windows uses `sqflite_common_ffi` with the same schema and Dart repositories.
Its `main_windows.dart` target initializes the FFI factory before bootstrap,
keeping the Android/iOS entrypoint free of desktop database initialization.
The sqlite3 hook resolves Windows' `winsqlite3.dll` and system SQLite on the
other platforms, avoiding an extra binary download during Android builds.
`WM_CLIPBOARDUPDATE` delivers text, PNG images and file paths to
`ClipboardManager`; copied images live under the private application data
directory and are deleted with trimmed history. Closing the main window hides it
to the system tray; explicit Exit destroys the runner. Text alone enters automatic
history sync, while file transfer remains an explicit device action. The runner
reports the clipboard-owner executable name when available so history can
apply the user-configured app exclusion list. A session-local mutex redirects a
second launch to the existing window so two listeners never write the same DB.
Windows screenshot actions are user-initiated from the History toolbar. The C++
runner freezes the virtual desktop before showing a temporary native selection
overlay. Region and display modes crop that snapshot; window mode selects a
top-level HWND and uses `PrintWindow` after hiding the overlay. PNG bytes return
over a method channel, then Dart copies the image and persists it through the
same local image-history path as clipboard images. The overlay and full-screen
bitmap are released after confirmation or cancellation; no capture loop runs
while the app is idle. A window that refuses `PrintWindow` returns a visible
failure rather than saving pixels from a different window. Some protected or
GPU-rendered windows can still return a blank frame despite `PrintWindow`
reporting success; Windows device acceptance must cover representative apps.

iOS attaches its Flutter UI after core bootstrap (Android's Activity still owns
`ui.attach`). Native `UIPasteControl` sends user-pasted text to history; there is
no background clipboard polling. The app's documents directory holds received
files and is visible in Files. The foreground sync listener stops when the app
is backgrounded and restarts on resume. Android notifications received over LAN
are stored and shown read-only on Windows/iOS; those platforms do not request
Android notification-listener permissions.
Stopping sync invalidates in-flight discovery and handshakes before closing the
listener, cancels reconnect work and discards incomplete file transfers. A new
foreground run uses a new connection generation, so a late result from the
previous run cannot reopen a background session. Reconnection then fetches
missed text history and flushes peers' durable pending messages.

## Ownership and data flow

| Concern | macOS | Flutter / Android, Windows, iOS |
| --- | --- | --- |
| Clipboard | `ClipboardManager` | `ClipboardManager`, native clipboard channel |
| Persistence | `AppDatabase`, `HistoryRepository` | `database/` repositories, storage channel |
| Sync orchestration | `SyncManager` | `sync_manager.dart` |
| Wire contract | `SyncProtocol.swift`, `SyncCrypto.swift` | `sync/protocol.dart`, `sync/crypto.dart` |
| Notification delivery | `NotificationManager`, `SystemNotificationRouter` | notification manager; Kotlin listener on Android, read-only mirror on Windows/iOS |
| UI lifetime | `WindowSession`, window controllers | feature widget state + subscriptions |

Local clipboard changes are normalized and deduplicated, persisted, then offered
to authorized sync peers. Remote history must be persisted **before** ACK.
The UI reads repository summaries/pages rather than owning the entire database.
Receiving remote content must not create an infinite rebroadcast loop.

Snippets have their own macOS manager and persistence. Screenshot entry points
call `NativeScreenshotCoordinator`, which owns one temporary selection, long
capture or recording session. The selection overlay owns its inline annotation
canvas and attached tool/action strips; an explicit editor action opens the
detached image editor. It returns one flattened captured image to delivery,
which encodes it, adds it to clipboard history once, and applies the selected
copy/save/pin/OCR action. Recording choices live beside the still-visible
selection, then the coordinator removes every selection window before starting
ScreenCaptureKit. Long-capture and recording HUDs release their windows,
timers and monitors when stopped or cancelled. Recognition, translation and
redaction require an explicit user action. The capture, annotation, recording
and WebP encoding modules stay independent from clipboard, sync and application
windows.
Floating thumbnails retain bounded compressed PNG data; save, Quick Look,
transform and batch export run on demand. The video editor stores effect
segments on a source-time timeline and applies cuts, speed changes and visual
effects on export. Hidden recording controls remain available from both status
item surfaces, while input warnings briefly reveal the excluded recording HUD.

## Menu-bar control panel (macOS)

`MenuController` owns the status item and routes left clicks to `MenuBarPanelController`,
while right clicks retain the native menu. The controller uses a nonactivating panel,
closes before external actions, and validates caller/clipboard/generation before paste.
The panel controller is created on first left click; background clipboard/device
updates must not force its initialization.
`MenuBarPanelModel` owns ephemeral tab, search and selection state; a serial cancellable
worker uses the existing history search service. `MenuBarPanelView` renders the approved
compact panel with shared typography, SF Symbols, language observation and semantic colors.
While recording is active, the open panel reads coordinator state and shows
pause, stop and cancel controls without polling.
Existing manager callbacks refresh only the open panel; there is no new idle polling.
Native menu tracking defers those refreshes. Dismissal cancels queries and releases the view.

Devices, notifications, snippets and tool actions use the existing managers/windows.
The panel does not alter clipboard persistence, Android or the sync protocol. Tests in
`MenuBarPanelRegression.swift` cover query races, close/reopen, geometry, keyboard selection
and focus guards. The optional `CLIPY_PANEL_SNAPSHOT_DIR` core-test environment variable
renders app-owned light/dark fixtures with fictional data and no real clipboard writes.

## Hidden menu bar icons (macOS)

`MenuBarOverflowManager` publishes an in-memory snapshot for `MenuController` and
its opt-in General setting. `MenuBarItemProvider` reads `AXExtrasMenuBar` on one
bounded worker and classifies full hosted-window bounds against the notch and front
application menus (AX buttons are inset and may appear to fit while their window is hidden).
Workspace activation refreshes retain the previous snapshot until new results arrive;
disable, permission loss, sleep/lock and display changes still clear it immediately. Kernel process start times and retained AX element identity
prevent PID/ordinal reuse from targeting a different item. Control Center owns
many hosted status windows on macOS 26; `MenuBarSystemBridge` optionally correlates
those windows by geometry instead of treating the hosting PID as app identity.
Missing private symbols leave the AX/application-icon path available.

Background checks read metadata only. Opening the panel or classic menu requests
bounded ScreenCaptureKit previews of matched windows (macOS 14+ with existing
Screen Recording permission); failures retain application icons and names. The
classic menu remains a snapshot; the panel observes the published state. Clicking closes the panel or ends menu tracking before issuing
one AXPress; unsupported or stale targets are not replaced with coordinates or
application launches. An AX timeout is an unconfirmed result because native menu
tracking can delay the reply even after the menu opens. Never automatically retry
it or cover it with a modal failure alert.

Disable, display changes, sleep/lock and permission loss invalidate pending work.
Only one built-in screen is supported. `menuBarOverflowEnabled` defaults to false;
window IDs, images and AX elements are never persisted or synchronized. Ordinary
regressions mock lifecycle races; the explicitly enabled live tests use temporary
status items and test original menus/popovers without moving existing icons.
The 15-second AX refresh timer exists only while a panel or classic menu is open;
closing it cancels outstanding preview work. Workspace/display events can still
refresh metadata while idle without starting a polling timer.

## Critical lifecycle contracts

- Android owns one cached Flutter engine. `PlatformChannels.registerAll` is
  Application-owned so storage/notification processing works without an Activity.
- `lib/app/bootstrap.dart` mounts a minimal root immediately using the default
  `main` entrypoint. Native `ui.attach` mounts the full Android UI; do not introduce
  a custom entrypoint or require a visible page to acknowledge sync traffic.
- FGS/watchdog types in Kotlin must match both service declarations in the
  manifest, including WorkManager's `SystemForegroundService`.
- macOS sync socket operations run on `syncQueue`; file work has a separate
  queue. The on-queue writer and external synchronous wrapper are distinct to
  prevent reentrant deadlocks. Sockets must remain nonblocking with bounded waits.
- OCR child dispatch runs before `NSApplication.shared`. Large media/CI caches
  and closed-window models need explicit idle release paths.
- Idle reclaim skips every visible content window or panel, including capture
  overlays and pinned images. Reclaim observer registration is idempotent.
- Screenshot sessions release capture streams, event taps, camera/microphone
  sessions, overlays and bounded image slices on finish or cancel. Do not sweep
  another application's temporary directories.

## Where to change behavior

- Wire fields, ACK rules, framing: update both sync implementations and
  [PROTOCOL.md](PROTOCOL.md), then run protocol tests and bidirectional device checks.
- Flutter navigation/pages: `lib/features/`; startup and channel registration:
  `lib/app/bootstrap.dart` (not a feature widget).
- Android timer: `TimerWidgetProvider`, `TimerSetupActivity`, `TimerWheelPicker`,
  `TimerRinger`, `TimerRingingActivity`, and related resources.
- Shared macOS window appearance: `Sources/UI/` and `WindowSession`; screenshots
  and pin panels have separate overlay lifetimes.
- Version/build metadata: `pubspec.yaml` and `scripts/lib/build_common.sh`.

See [Development](DEVELOPMENT.md) for verification boundaries and
[the AI change guide](AI_CHANGE_GUIDE.md) for ownership, lifecycle and memory
checks. See also
[third-party notices](../THIRD_PARTY_NOTICES.md) before updating the screenshot
module or its statically linked WebP encoder.
