# Architecture and code map

Clipy keeps its Swift/AppKit macOS menu-bar application. The Flutter application
shares UI, history storage and the v3 LAN protocol across Android, Windows and
iOS. Kotlin owns Android background services, the Windows C++ runner owns the
system clipboard and tray, and Swift owns iOS user-initiated paste and sandbox
paths. Main-app platform adapters retain the shared protocol implementation;
the iOS Share Extension has a bounded native one-shot client for the same wire
contract, without starting a second background sync service.

## File receipt notifications

A receipt is posted only after SHA-256 verification, final rename and database
commit. The native notification channel is best-effort and cannot change the ACK
or completed-transfer state. Android registers it on the Application engine so
background reception works; immutable PendingIntents carry bounded, private path
tokens and cold/warm Activity taps reuse folder opening with viewer fallback.
iOS requests alert permission on UI startup, shows foreground banners, and stores
Documents-relative paths so taps survive sandbox relocation. A pending tap waits
for scene activation, then previews the file or offers opening options. Missing
files produce a message. macOS requests normal alert permission and reveals the
final file in Finder; missing files fall back to the receive directory. Windows
uses native tray receipts with separate IDs (maximum 32); taps reveal in Explorer,
and native resources are released on timeout, tap, Explorer restart or app exit.
Notification permission, Focus mode and OS policies still control presentation.
No new polling, network service or file-content duplication is introduced.

## Repository layout

### Mobile incoming shares

- Android `SharedFileInbox` accepts `SEND` / `SEND_MULTIPLE` with `*/*` through
  `MainActivity.onCreate` and `onNewIntent`. It deduplicates stream/ClipData URIs,
  reads granted `content://` streams on one expiring worker, and bounds the inbox
  to four batches, 32 files per batch, 1 GiB per file and 4 GiB staged in total.
  Available disk capacity reserves 64 MiB. It rejects private `file://` paths
  and this app's own FileProvider; missing display names use a safe fallback.
- iOS `ShareExtension` reviews files and selects/sends to a device inside the
  system share sheet. UIKit uses the same file-list/device-choice/Send sequence
  as Android. It never opens the main app or starts a Flutter engine. File-provider
  reads coordinate security-scoped URLs, try alternate representations and copy
  in 64 KiB blocks through `Shared/ShareInboxStore`; the same size/count limits
  apply, with distinct size/storage/read errors and cancellation between reads.
- `ShareSettingsStore` exchanges only name, language, listening port and up to
  128 cached endpoints via the App Group. Flutter publishes a snapshot on UI
  startup/resume and peer changes. Explicit Refresh probes those endpoints and
  at most two physical-interface /24 ranges, with 12 concurrent short-lived
  connections; manual IPv4/port discovery is available. No idle scan or listener.
- `ShareTransferClient` is an extension-safe, one-shot v3 sender using the same
  default AES-GCM key, JSON frames, 1 MiB chunks, SHA-256 and final ACK contract.
  Its separate session identity never replaces the containing app's session.
  It verifies the selected peer ID on connect, handles ping/early rejection,
  bounds each frame, and streams one chunk at a time. Closing cancels sockets,
  file-provider reads and pending scans; temporary files are then removed.
- Android's `incoming_share.dart` drains one batch at a time; `SharedFilesPage`
  requires explicit device selection/Send and skips successes on same-peer retry.
  Closing removes the batch. iOS retains this bridge only to drain legacy staged
  shares. New iOS shares are never published to that main-app queue.
- Android clears process-orphaned files on the next share. iOS excludes temporary
  files from backups and prunes entries older than 24 hours on the next import.
  There is no cleanup timer; the Android worker expires after 30 seconds idle.
- Flutter file receivers pause socket reads with two decrypt/write operations
  in flight, draining buffered frames before resuming. This bounds memory for
  1 GiB transfers even when native decryption is slower than the network.

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
  Sources/Screenshot/         capture/annotation/recording engine and adapters
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

Snippets have their own macOS manager and persistence. Screenshot confirmation
passes through `ScreenshotSessionCoordinator` into clipboard history, optional
save/sync and thumbnail presentation; screenshot internals should use the app
integration protocol instead of reaching directly into unrelated controllers.

## Menu-bar control panel (macOS)

`MenuController` owns the status item and routes left clicks to `MenuBarPanelController`,
while right clicks retain the native menu. The controller uses a nonactivating panel,
closes before external actions, and validates caller/clipboard/generation before paste.
The panel controller is created on first left click; background clipboard/device
updates must not force its initialization.
`MenuBarPanelModel` owns ephemeral tab, search and selection state; a serial cancellable
worker uses the existing history search service. `MenuBarPanelView` renders the approved
compact panel with shared typography, SF Symbols, language observation and semantic colors.
`MenuBarPanelPolicy` provides a compact preferred size per home tab/detail page, with
the Devices page scaled to its count; the controller observes navigation and device
updates and repositions the visible panel under its status item.
Detail pages replace the home search/strip/tabs/footer with a Back/title row, while
the Tools tab omits actions already present in the home footer.
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

## Default LAN transport

Current source uses protocol v3 with the same built-in AES-GCM key on every device.
There is no pairing configuration, QR import or handshake proof. Version checks
reject v2 peers; outgoing automatic sharing choices remain independent of direct
text/file sends. The first upgrade clears obsolete encoded pending frames only,
retaining local history and user data. See PROTOCOL.md and SECURITY.md.

## Critical lifecycle contracts

- iOS uses `FlutterSceneDelegate` with a single scene. Register plugins, storage
  channels and the native Paste control in `didInitializeImplicitFlutterEngine`;
  file presentation resolves the foreground scene's key window rather than
  `AppDelegate.window`. Dart stops sync when hidden/paused and restarts on resume.
  Clipboard imports remain user initiated; remote items do not overwrite the
  iOS system clipboard automatically.

Token usage refreshes stream up to 365 local calendar days from SQLite into daily
agent/model aggregates on the existing worker. Individual events are released as
they are read; the published report retains aggregates only. The detail view builds
a bounded 365-day heatmap from that report, with at most 53 week columns and no
additional log scans, timers or persisted chart state. Hover/click state belongs to
the view and resets when the agent filter changes or the hosting view is released.

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
- Screenshot scratch/cache directories are Clipy-owned; never sweep macshot's
  or another application's directories.

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
[third-party notices](../THIRD_PARTY_NOTICES.md) before updating the screenshot port.

## Smart Switch paste-back target

`SmartSwitchWindowFocusSession` captures a metadata-only `SmartSwitchDeliveryTarget` before presentation and validates it after closing. The bounded focus worker reads process launch identity, window and editable element identity; mismatches and unresolved targets retain copied text with a nonactivating hint. Clipboard versions and session generations also gate the final PID-addressed key pair. `keySent` records dispatch only, never verified insertion. The target is transient and cleared on close or handoff; no editor contents, persistent observer or polling is added.
