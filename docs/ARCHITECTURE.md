# Architecture and code map

Clipy uses Swift/AppKit on macOS and Flutter for Android, Windows and iOS
releases. A native Kotlin/Compose Android port is kept as an alternative with the
same application ID and data files. Windows C++ owns the clipboard and tray;
Swift owns iOS user-initiated paste and sandbox paths. All clients retain the v3
wire contract; iOS Share Extension uses a bounded native one-shot client without
starting a second background sync service.

## Native Android alternative (not released)

`clipy_android_native/` contains the Android UI, SQLite repositories, LAN v3
protocol/session/file pipeline, notifications, sharing, timer widgets and relay
integration. `build_android_native_apk.sh` builds it with `nativeProduction=true`, the
original application ID and the existing release keystore. Debug previews keep
an isolated `.nativepreview` ID. Flutter is not an Android build/runtime dependency;
its pubspec remains the shared version source. Public Android builds default to
source build +2000 to continue historical ARM64 numbering; explicit BUILD_NUMBER
is the actual versionCode. See [DEVELOPMENT.md](DEVELOPMENT.md).

`ClipyApplication` owns the coroutine scope and sync/relay/notification/file
managers. Compose observes snapshots; durable operations do not depend on a
visible Activity. `NativeLegacyMigration`, unchanged database fields, existing
FlutterSharedPreferences names and the compatible Java secure-storage adapter
preserve local history, identities, settings and enrollment. Credential decode
failures never clear data or silently regenerate identity. [NATIVE_MIGRATION.md](NATIVE_MIGRATION.md)
and [the parity checklist](NATIVE_MIGRATION_PARITY.md) track acceptance evidence;
source cutover alone does not assert release publication or final device parity.

## File receipt notifications

A receipt is posted only after SHA-256 verification, final rename and database
commit. The native notification channel is best-effort and cannot change the ACK
or completed-transfer state. Android uses Application-owned native file callbacks so
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
- Android text-only shares retain `EXTRA_TEXT` (or one plain ClipData item)
  in the bounded inbox, with a 1 MiB UTF-8 limit and at most four batches.
  The review page previews text and sends via `sendTextToPeer` (`history.direct`)
  after explicit device selection; no text file is created. Completion/cancellation
  releases the batch. Actual text-file URI attachments remain file transfers.
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
- Android `MainActivity` observes `SharedFileInbox` and opens the native
  `SharedFilesPage`. `ShareSendSession` requires explicit peer selection and
  Send, skips successful files on same-peer retry, and closes a successful review.
  Its UI observes application-owned transfers; explicit completion/cancellation
  releases the staged batch. Visible review refresh reuses live
  sessions and probes remembered/manual endpoints before bounded subnet discovery.
  `DiscoveryRefreshCoordinator` coalesces refresh requests; sync stop invalidates
  pending discovery. There is no idle share-page polling. Flutter's
  `incoming_share.dart` remains a reference and an iOS bridge for legacy staged
  shares; new iOS shares are not published to that main-app queue.
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
  Sources/Screenshot/         capture/annotation/recording engine and adapters
  Sources/UI/                 shared SwiftUI views and window layouts
  Resources/Info.plist        reviewed bundle/permission metadata template
clipy_android_native/
  app/src/main/java/com/clipyclone/
    nativeandroid/           Compose UI, repositories, LAN/files, relay, notifications
    clipy_android/           Application, original service/widget component names
  app/src/main/assets/       icons/fonts and packaged third-party notices
  app/src/test/              deterministic native JVM tests
  app/src/androidTest/       Android storage/crypto/socket/integration checks
clipy_android/               Windows/iOS implementation; Android parity reference
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
keeping the iOS/reference Android entrypoint free of desktop database initialization.
The sqlite3 hook resolves Windows' `winsqlite3.dll` and system SQLite on the
other Flutter targets. Native Android uses the platform SQLite APIs.
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

iOS attaches its Flutter UI after core bootstrap. Native Android mounts Compose
directly and has no `ui.attach` or Flutter engine lifecycle. Native `UIPasteControl` sends user-pasted text to history; there is
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

| Concern | macOS | Native Android | Flutter Windows/iOS and Android reference |
| --- | --- | --- | --- |
| Clipboard | `ClipboardManager` | `NativeClipboard` | `ClipboardManager`, native clipboard channel |
| Persistence | `AppDatabase`, `HistoryRepository` | `ClipyDatabase`, `HistoryRepository`, `PendingSyncRepository` | `database/` repositories, storage channel |
| Sync orchestration | `SyncManager` | `NativeSyncManager` | `sync_manager.dart` |
| Wire contract | `SyncProtocol.swift`, `SyncCrypto.swift` | `sync/` protocol/crypto/session modules | `sync/protocol.dart`, `sync/crypto.dart` |
| Notification delivery | `NotificationManager`, `SystemNotificationRouter` | `NativeNotificationManager`, existing listener component | notification manager, read-only mirror on Windows/iOS |
| UI lifetime | `WindowSession`, window controllers | Compose route state, view models, lifecycle-aware flows | feature widget state + subscriptions |

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
the Devices tab scaled to its count; the controller observes navigation and device
updates and repositions the visible panel under its status item.
The Devices tab has a refresh button (prune + full /24 scan) and per-device Send Text /
Send File buttons. Detail pages replace the home search/strip/tabs/footer with a
Back/title row. Tools is the fourth home tab: a capture row directly launches region/window/full-screen,
followed by Lookup/Vocabulary and a Password action. `MenuBarPanelToolsView`
owns this layout and uses the same model/action handoff. Its header shares the same hidden-icon strip as other home tabs;
Tools keeps the Clipboard/Snippets panel size, with its content scrolling independently. The footer contains named Keep Awake
and Notifications controls; banner preferences remain in More. No new background work or persistence is introduced.
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
Each attached display is evaluated against its own menu-bar geometry. `menuBarOverflowEnabled` defaults to false;
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

- Native Android `ClipyApplication` initializes managers/repositories without a
  Flutter engine. Sync commits incoming history before ACK even without UI.
- Android `MainActivity` retains `singleTask` and the application task affinity.
  Launcher, shares and notification taps reuse the same native Activity through
  `onNewIntent`. Original service/widget component names are preserved for
  upgrades; no migration may depend on an uninstall or permission reset.
- Compose route/tab state survives navigation with `ActivePageLayout`; hidden
  pages suppress dialogs, focus, animations and page-owned polling. Application
  scope owns submitted durable operations. The group watcher is bounded to one
  two-second check while a visible foreground page has pending work.
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
- Android native navigation/pages: `nativeandroid/MainActivity.kt`, `ui/` and
  view models; lifecycle/managers: `clipy_android/ClipyApplication.kt` within the
  native Java source root. Read `NATIVE_MIGRATION_PARITY.md` before changing contracts.
- Flutter Windows/iOS and reference navigation/pages: `lib/features/`; bootstrap:
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

## Optional Internet relay

`SyncRelayClient.swift`, native Android `relay/NativeRelayTransport.kt`, and
Flutter `sync/relay_client.dart` own authenticated WSS presence
and bounded per-peer byte bridges; SyncManager starts/stops them with sync and
validates peer identity/generation before adoption. Private LAN probes take
priority; relay addresses never overwrite the LAN cache. The vendored Common Relay SDK provides authenticated, end-to-end encrypted streams and verified group membership. Android reuses its Java SDK through loopback socket bridges into the same v3 session/ACK/file pipeline; `NativeRelayController` owns settings and group state. The original secure-storage aliases and Dart journal format are preserved. Packaged provenance and licenses are in APK `assets/third_party/`. `relay/server.py` documents the retired service only. See [COMMON-RELAY-SDK.md](COMMON-RELAY-SDK.md) for current setup and the separate LAN trust boundary.

## Internet relay configuration and routing

`SyncRelaySettings` / `RelayConfiguration` merge the editable relay device ID and
access token into existing secure enrollment, retaining identity keys and trusted
peers. A blank token keeps the stored token. UI loading is read-only; explicit
save rebuilds relay connections only. Device IDs follow the server's 1–80 character
letters/digits/underscore/hyphen rule; access keys are validated before secure persistence.

The relay device alias is independent of the stable LAN peer UUID. Authenticated
presence advertises the LAN `peerId`; relay clients map aliases to that ID before
dialing LAN or adopting a tunneled session. Legacy presence without this field
uses its relay ID only when that ID is a UUID. Both transports share one active
session per LAN peer, with LAN preferred. Manual discovery refreshes both LAN
and relay presence; queued sending also nudges relay reconnection. No extra
background polling or duplicate business session is introduced.

### Relay group management

`SyncRelayGroups` / `sync/relay_groups.dart` own private enrollment drafts, invitation persistence and verified membership updates. `SyncRelayGroupView` / `RelayGroupPage` own visible group-management actions. The common-relay SDK owns signing, chain verification and HTTP management calls. Before opening a managed relay connection, the client verifies newer membership entries; a revision-bearing `group.changed` event closes stale relay sessions and triggers a verified reconnect. LAN listeners and existing LAN sessions are not restarted by group management.

### Relay group creation

Unenrolled devices can create a group or join an invitation. SDK `prepareCreate` generates a random group namespace and client-signed root. The app saves the draft in private storage before calling `create`, then persists the verified membership and enables relay transport. Retries reuse the saved request. Existing group credentials are never silently replaced. Creation uses the configured relay URL and requires the server to enable self-service for Clipy. Group pages separate onboarding, members, invitations and approval; no background polling is added.

Group exit drafts bind to the original server/group/device/token and survive response loss. Clearing enrollment stops only relay sessions, rotates the relay device ID and preserves LAN identity/history. Member names are signed display metadata: users rename themselves, managers may rename any member. The UI keeps exit/disband separate from device actions and confirms scope before changing membership.

A group management HTTP 401 invalidates the UI’s active-membership state. Cached names/roles cannot remain actionable. The recovery card explains that the group may have closed or the device been removed; explicit local cleanup returns to onboarding while preserving identity keys, history and LAN settings. Ordinary connection errors still preserve the cached configuration for retry.

### Automatic invitation progress

Scanning an invitation submits the join request. While the group page is open, a single serialized check runs every two seconds only when a pending join or outgoing invitation exists. The inviter displays verified requests automatically above the QR code; approval remains explicit in manual mode. The applicant verifies approval with the existing SDK, persists membership and enables relay without a second confirmation. Closing the page cancels checks; Android pauses checks in the background and resumes on foreground. Reopening loads the private draft and resumes. Completion, discard, cancellation, expired outgoing invitations, or terminal HTTP errors stop checks; manual refresh can retry. No permanent background poller is introduced.

Relay invitations default to automatic joining after scanning, with manual pairing-code approval available by turning the option off. Automatic admission verifies a time-limited manager-signed delegation and grants ordinary membership; the inviter need not remain online. QR codes and copied invitations use encrypted short links, while legacy invitations remain supported. Existing members must upgrade to the delegation-aware SDK; the server must support automatic admission and invitation-link endpoints.

## Fast LAN / relay handoff

Network-interface changes, peer reconnection and explicit device refresh trigger a bounded 3-second ping check. A fresh pong preserves a healthy session; only the captured session without a newer pong is retired, then relay discovery runs immediately. Repeated refreshes share the deadline; stop cancels the probe and lifecycle checks reject stale callbacks. Relay refresh wakes a pending retry, uses known presence immediately, coalesces roster requests and reconnects after a 3-second roster timeout. Wi-Fi/cellular changes are handled without requiring an offline interval. No new permanent poller is added; LAN preference and trust checks remain.
