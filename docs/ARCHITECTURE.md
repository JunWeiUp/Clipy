# Architecture and code map

Clipy contains two native integration surfaces: a Swift/AppKit macOS menu-bar
application and a Flutter application with Android/Kotlin background services.
The Flutter tree also contains an experimental iOS target; Android-native
capabilities and CI coverage must not be assumed to exist on iOS.

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
  Sources/Screenshot/         capture/annotation/recording engine and adapters
  Sources/UI/                 shared SwiftUI views and window layouts
  Resources/Info.plist        reviewed bundle/permission metadata template
clipy_android/
  lib/main.dart              default Dart entrypoint only
  lib/app/                   bootstrap, headless bridge, application root
  lib/features/              devices, history, settings, logs, transfers
  lib/database/              repositories and migrations
  lib/sync/                  protocol, crypto, sessions, discovery, reliability
  lib/ui/                    shared history widgets
  android/app/src/main/      Kotlin services, platform channels, timer widget
  test/                      deterministic Flutter/protocol tests
  tool/                      explicitly invoked integration probes
scripts/                     shared build configuration and local checks
docs/                        architecture, development, wire protocol
.github/                     CI, release drafts, contribution templates
```

Existing managers, models, localization and notification UI remain directly under
`lib/` to keep their import/API surface stable. Move these by feature in focused
follow-ups with tests; do not mix a protocol rewrite with directory reorganization.

## Ownership and data flow

| Concern | macOS | Flutter / Android |
| --- | --- | --- |
| Clipboard | `ClipboardManager` | `ClipboardManager`, native clipboard channel |
| Persistence | `AppDatabase`, `HistoryRepository` | `database/` repositories, storage channel |
| Sync orchestration | `SyncManager` | `sync_manager.dart` |
| Wire contract | `SyncProtocol.swift`, `SyncCrypto.swift` | `sync/protocol.dart`, `sync/crypto.dart` |
| Notification delivery | `NotificationManager`, `SystemNotificationRouter` | notification manager + native listener service |
| UI lifetime | `WindowSession`, window controllers | feature widget state + subscriptions |

Local clipboard changes are normalized and deduplicated, persisted, then offered
to authorized sync peers. Remote history must be persisted **before** ACK.
The UI reads repository summaries/pages rather than owning the entire database.
Receiving remote content must not create an infinite rebroadcast loop.

Snippets have their own macOS manager and persistence. Screenshot confirmation
passes through `ScreenshotSessionCoordinator` into clipboard history, optional
save/sync and thumbnail presentation; screenshot internals should use the app
integration protocol instead of reaching directly into unrelated controllers.

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
[third-party notices](../THIRD_PARTY_NOTICES.md) before updating the screenshot port.
