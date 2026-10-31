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

On History, Notifications and Settings, the page title/intro collapses after scrolling 48 logical pixels and returns at the top for long lists. Lists whose maximum scroll extent is at most 48 pixels also collapse after 24 pixels of user drag in either direction, so a short history can reclaim the intro space without reaching an impossible scroll offset. Short-list collapse stays stable at zero offset and resets when changing main tabs. Search, filters and the app bar remain available. Header motion respects reduced animations. Devices omits its page heading. Android notification lists inside TabBarView use scroll notification depth 1; other pages use depth 0. Horizontal swipes and viewport changes alone do not collapse headings.

## Feature ownership

System sharing opens a separate file-review page on Android and iOS. Show the
received filenames and sizes before device selection; Android text-only shares
show a bounded scrollable text preview and use direct text sending; enable Send only after
the user chooses a peer. Send sequentially, show per-file success/progress, and
keep failures available for retry without resending successful files to the
same peer. The share page discovers on open/resume, shows a Refresh action and
probe progress, and distinguishes sync-off from a completed empty search. The
Devices link preserves the share while enabling sync or adding a manual IP;
returning retries discovery subject to the shared cooldown. Closing the review
removes temporary files; a fully successful send closes it automatically.
On iPhone the native share extension
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

Run `flutter analyze --no-pub` and `flutter test --no-pub` from `clipy_flutter/`, then build the affected Android target. The controller/repository tests cover concurrent refreshes, stale searches, literal query escaping and filtering before pagination. Widget tests cover invalid-port protection, small-screen large-text settings and cancellation of destructive actions.

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

The Devices page leads with device cards instead of the introductory banner and
connection form. Online peers precede saved offline peers. Text/file send actions
remain directly visible; automatic clipboard/notification switches open from the tuning icon in
the card header (one card at a time). Compact cards use a 36px device icon,
8px bottom spacing and no separate expansion row. The Devices tab omits the
large page title and local-connection subtitle, keeping the list heading only. Connection settings, diagnostics and manual addresses follow the list.
The shared desktop settings list retains expanded switches. Refresh progress and
empty-state guidance remain visible, with no new subscriptions or polling.

The Devices sync button reflects live sessions, not merely a bound listening
socket: LAN, relay, and mixed routes have distinct labels. Relay control
connecting, retrying, and ready-without-peers are separate states; discovery,
waiting, disabled, and toggle-in-progress are also explicit. Connection and
discovery events refresh the view; listeners are removed on disposal, with no
new timers. An enabled button retains its tap-to-disable action and visible hint.

### Relay form state and narrow layouts

- Relay fields and the enrollment disclosure each use a distinct `PageStorageKey`.
  The Devices list retains its scroll position; the disclosure's boolean state must
  never share a storage identifier with a text field's numeric scroll offset.
- Device IDs and relay addresses wrap without accepting line breaks. Helper text
  wraps for large fonts; the save button spans the card width. Enrollment stays
  obscured and drafts survive disclosure collapse, without saving or restarting sync.
- `relay_settings_layout_test.dart` covers a 320 dp viewport, 2× text, Chinese/English,
  both themes, repeated disclosure toggles, keyboard insets and save-button reachability.

## Relay invitation progress

Scanning a device-group QR code submits the request. While this page is open, requests appear automatically above the invitation QR; manual mode requires the inviter to compare the pairing code and explicitly approve. Approval automatically completes enrollment on the requesting device. Do not require “Check join request” or “Finish joining” buttons. Keep discard/cancel controls and inline network/expiry feedback.

Relay invitations default to automatic joining after scanning, with manual pairing-code approval available by turning the option off. Automatic admission verifies a time-limited manager-signed delegation and grants ordinary membership; the inviter need not remain online. QR codes and copied invitations use encrypted short links, while legacy invitations remain supported. Existing members must upgrade to the delegation-aware SDK; the server must support automatic admission and invitation-link endpoints.

## Native migration preview

The independent Kotlin/Compose history slice in `clipy_android_native/` uses Material 3
semantic light/dark themes, localized English/Chinese strings, native clipboard
actions and explicit deletion confirmation. It identifies itself as a local-only
preview and does not show fake device/sync controls. See [migration gates](NATIVE_MIGRATION.md)
for the remaining navigation, system integration and parity requirements.
