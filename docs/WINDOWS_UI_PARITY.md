# Windows V3 implementation and verification

The Windows baseline is the locally maintained `UI/design-v3/` design. Windows
continues to use Flutter for its pages and the C++ runner for desktop integration;
this work does not restart the separate NSH migration.

## Implemented

- One 48 logical-pixel title bar (`WindowsTitleBar`) with native move, minimize,
  maximize/restore and close-to-tray actions. Win32 retains its resize frame.
  Pushed routes (logs, received/shared files, connection settings, diagnostics and
  relay groups) retain the same caption plus Back and their existing page actions.
  Main/quick/capture window modes remain owned by the runner.
- History navigation counts use SQL aggregates, not loaded history bodies.
  Search, type filters, date sections, preview metadata, image dimensions,
  copy and explicit text/image/file sends use existing storage and sync owners.
  Sending a folder requires making a ZIP first; file-location history is retained.
- The quick panel has tools, search result counts, icon filters, image-first cards,
  selection feedback and online-device/file navigation. Copy-only and safe paste
  remain separate actions. Count requests are debounced and stale results ignored.
- Devices are grouped by online/offline status, with manual addresses and a direct
  validated IP dialog. Stopping discovery invalidates queued probes without
  stopping synchronization or established sessions.
- Windows file transfers support drop/multi-select, progress, mean throughput,
  ACK-confirmed completion, cancellation and whole-file retry. The lazy application
  session controller retains at most 100 records and four active peer sends, one
  send per peer. It uses streams, not polling, and stores no file contents.
  Switching pages does not redirect or silently cancel a user-started send.
- Cancelling a file send stops subsequent chunks without closing the shared
  socket. Bytes already buffered may still arrive. An incomplete receiver file is
  removed by its existing timeout; retry uses a new file ID and sends from the
  beginning. A retry cannot overlap the cancelled sender's outstanding flush.
- Phone notifications have source summaries, application grouping, search,
  all/unread filtering, independent verification-code copy, details and preferences.
  Read/source metadata is local to the existing SQLite notification row; deletion
  and retention remove it with the row. Filtering happens before 40-row pagination.
- Windows notification banners are opt-in. Accepted posts are stored and ACKed
  before best-effort native presentation. Duplicate delivery does not show a new
  banner. The runner retains at most 16 phone-notification resources, separate from
  file-receipt resources; clicking opens the notification page.
- Settings use the shared Windows controls, an expandable close-to-tray card,
  explicit shortcut purpose/status, a separate firewall section and installed
  version metadata. Firewall-enabled status is not a claim that app access is allowed.
- Screenshot overlay uses localized icon/text controls, 0/3/5-second delay,
  eight selection handles, moving/resizing and an actual-pixel HUD. Dragging sets
  a selection; Enter, double-click or Confirm completes it. Esc/right-click cancel.
  The frozen desktop and dimmed bitmap still use the existing BitBlt paint path.

## Explicit remaining differences

- The current peer protocol has no platform or RTT metadata. The UI uses a generic
  device icon and does not infer a platform from the user-editable device name.
- Native notifications currently use `Shell_NotifyIcon` (`NIF_INFO`). The draft's
  rich thumbnails, two action buttons, multi-file aggregation and durable notification
  center actions are not implemented. OS notification and Focus settings govern display.
- Screenshot element-level snapping is not implemented. Window/display selection
  and region adjustment are supported; the HUD does not claim element snapping.
- Windows security/firewall windows are OS-owned illustrations in the design,
  not dialogs the application may simulate. LAN and configured relay connectivity
  are both supported; the old “never connects to the cloud” wording is invalid.

## Verification

The current change passes Flutter analysis, all 168 Flutter tests, repository
checks and whitespace checks. The route-caption regression checks Back, page
commands and native window-command dispatch after navigation.

A Windows x64 Release build (1.0.35+12366) was installed and launched in the existing
Windows VM, preserving application data and backing up the prior program bundle.
Desktop checks passed for maximize/restore, minimize, close-to-tray, three
capture/cancel cycles and quick-panel open/close. The native screenshot regression
passed adjustable region/window/display PNG, Enter/Esc/cancel, single completion
and ten repeated sessions. An actual main-window screenshot was inspected.
The SMB mapping cannot create plugin symlinks, so this build used an explicitly
authorized disposable NTFS source copy.

Relevant coverage is in `clipy_flutter/test/windows_*`,
`test/clipboard_repository_test.dart`, `test/remote_notification_mirror_test.dart`
and the discovery/lifecycle tests. `windows_visual_regression_test.dart` renders
actual page widgets with isolated data; its optional `CLIPY_VISUAL_FONT` and
`CLIPY_VISUAL_DIR` outputs are component previews, not Windows desktop evidence.

Native regression is in `clipy_flutter/windows/tests/screenshot_regression.cpp`;
`scripts/test_windows_capture_flow.ps1` covers main/quick/capture transitions and
native window controls. C++ syntax checking on a non-Windows host does not replace
building and running these checks on Windows. Real desktop acceptance must still
cover high DPI, dragging, delayed capture, file drop, cancellation/retry and
notification clicks before claiming complete runtime parity.
