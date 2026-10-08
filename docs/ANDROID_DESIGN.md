# Android design and interaction

The mobile Flutter UI uses Clipy blue, semantic light/dark surfaces, generous typography and rounded cards. It follows Android navigation conventions while sharing the identity of the native Mac app.

## Shared components

- `lib/ui/app_theme.dart`: light and dark Material 3 themes, surface colors, type, fields, buttons, sheets and navigation. `AppAppearance` persists system/light/dark selection. Load it only when attaching the UI; the headless sync engine does not need a widget tree.
- `lib/ui/app_components.dart`: section cards, icon containers, actionable empty/error states, floating feedback and explicit destructive confirmation.
- `assets/branding/clipy-logo.png`: copy of the repository logo, registered in pubspec. Keep it aligned when the brand changes.
- Use semantic colors rather than fixed light gray fills. Keep interactive controls at least 48 logical pixels high. Let long translations and larger system text wrap.

## Navigation and motion

`HomePage` provides History, Devices, Notifications and Settings. It creates each page on first visit and keeps it in an `ActivePageStack`, preserving searches, scroll offsets and local state. Only the visible page is laid out when keyboard insets resize the body; hidden pages are excluded from focus, painting and semantics and use `TickerMode`. This stack requires bounded full-page constraints. Tab transitions fade over 220 ms and respect the platform's disable-animations preference. A navigation rail replaces the bottom bar from 720 logical pixels. Android Back returns to History before leaving the app.

Copy feedback uses a short checkmark transition and selection haptics. Confirmation is shown only after the clipboard write finishes. File-transfer progress remains visible across tabs. Avoid looping decorative animations or discovery polling for visual effects.

On History, the page title/intro collapses after scrolling 48 logical pixels and returns at the top for long lists. Lists whose maximum scroll extent is at most 48 pixels also collapse after 24 pixels of user drag in either direction, so a short history can reclaim the intro space without reaching an impossible scroll offset. Short-list collapse stays stable at zero offset and resets when leaving History. Search, filters and the app bar remain available. Header motion respects reduced animations. Other tabs retain their page headings; viewport changes alone do not collapse them.

## Feature ownership

System sharing opens a separate file-review page on Android and iOS. Show the
received filenames and sizes before device selection; enable Send only after
the user chooses a peer. Send sequentially, show per-file success/progress, and
keep failures available for retry without resending successful files to the
same peer. The Devices link preserves the share while enabling sync or refreshing
discovery. Closing the review removes temporary files. On iPhone the native share extension
shows the same file/size list, device selection and explicit Send flow in the
share sheet, with refresh/manual-IP controls and per-file progress/success. It
sends directly without opening the main app. Enforce 1 GiB per file and report
unreadable files, low storage and oversize files separately.

| Area | Implementation | Behavior |
| --- | --- | --- |
| History | `features/history/history_feed_controller.dart`, `ui/clipboard_history_list.dart` | Debounced full-database search, type filters, date groups, tap to copy, hold to preview/send, pull to refresh, recoverable errors |
| Devices | `features/devices/devices_page.dart`, `device_widgets.dart` | Local sync, peer capabilities, one-off sending, manual IPv4 peers, connection editor |
| Settings | `features/settings/mobile_settings_content.dart` | Appearance, language, timer-widget pinning, files and logs |
| Notifications | `notification_sync_page.dart` | Permission guidance, collection/sync filters, history and embedded overflow actions |
| Files and logs | `features/transfers/`, `features/logs/` | Shared styling, visible load failures and explicit deletion confirmation |

The existing native Android countdown widget and its hour/minute/second setup screen retain their dedicated timer design.

## State and data rules

- Apply history filters in SQL before LIMIT/OFFSET. Bind search text and escape LIKE metacharacters. Sort by timestamp and row ID for deterministic pagination.
- History card text summaries process at most 600 UTF-16 code units, without cutting a surrogate pair. Full text remains available for search, copy and preview; a three-line visual limit alone does not bound paragraph input.
- Serialize history loads. Replay a refresh that arrives during pagination, discard superseded searches, preserve the loaded extent when refreshing, and ignore results after disposal. Do not compare history as an unordered set: repeated copies can legitimately change the ordering.
- Validate the whole connection form before saving. Persist name and port together, then restart sync once. Do not save partial port values on each keystroke. Prevent duplicate saves/toggles while work is in flight.
- Do not silently erase a received-file record if deleting the file fails. Keep the record and show an actionable error.
- Keep sync and notification permission separate. Do not imply a discovered device is cryptographically authenticated, or that enabling the LAN server guarantees a live peer session.

## Verification

Run `flutter analyze --no-pub` and `flutter test --no-pub` from `clipy_android/`, then build the affected Android target. The controller/repository tests cover concurrent refreshes, stale searches, literal query escaping and filtering before pagination. Widget tests cover invalid-port protection, small-screen large-text settings and cancellation of destructive actions.

README captures use an isolated Android emulator and fictional database entries. Never use personal clipboard history, real notification content or pairing secrets in public images. Label source previews separately from published packages.

Device refresh shows a progress bar and completed/total endpoint probes until
the real scan and handshakes finish; discovered devices appear immediately. The
refresh action is disabled during scanning and reports the final device count,
including an explicit empty result. Leaving/reopening the page reads the manager's
current progress; disabling sync clears it. No UI timer or background scan loop
is added.

The Settings footer displays version and build number below the app description
on Android, iOS and Windows. Read native package/build metadata once per settings
view; do not hardcode the source version or poll for changes.
