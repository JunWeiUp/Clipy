# Remove Collector (Keep Notification Sync) Implementation Plan

> **For agentic workers:** Execute task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete phone collector end-to-end while keeping notification sync working via `notification/post`.

**Architecture:** Decouple Android notification broadcast from `collector/event` first, then delete collector UI/services/storage on Android and macOS. Notification sync continues through existing `notification/*` handlers.

**Tech Stack:** Flutter/Dart (Android), Kotlin (Android native), Swift/AppKit (macOS)

**Global Constraints:**
- Do not remove screenshot / ScreenCapture features
- Do not break clipboard history sync (`text/plain`)
- No simulator runs required for verification
- Do not commit unless user asks

---

## File Map

**Android delete:** collector_*.dart, collector_repository.dart, CollectorForegroundService.kt, CollectorEventBridge.kt, SmsReceiver.kt, SmsContentObserver.kt, CallStateReceiver.kt, CallLogObserver.kt, BootReceiver.kt (if collector-only)

**Android modify:** notification_manager.dart, sync_manager.dart, main.dart, models.dart, clipboard_manager.dart, app_database.dart, legacy_migration.dart, notification_health_monitor.dart, app_localizations.dart, AndroidManifest.xml, MainActivity.kt

**macOS delete:** DeviceCollectorManager/Repository/Types.swift, CollectorWindow.swift, UI/CollectorView.swift

**macOS modify:** SyncManager.swift, MenuController.swift, PreferencesManager.swift, SettingsView.swift, Localization.swift, AppDatabase.swift

**Docs:** README.md, AGENTS.md, Kim_AGENTS.md

---

### Task 1: Decouple notification broadcast (Android)

**Files:**
- Modify: `clipy_android/lib/notification_manager.dart`

- [ ] Change `_broadcastToSync` to send `notification/post` with `NotificationEntry` JSON (not CollectorEvent / collector/event)

```dart
void _broadcastToSync(NotificationEntry entry) {
  SyncManager.instance.broadcastNotificationMessage(
    type: 'notification/post',
    content: jsonEncode(entry.toJson()),
    hash: entry.id,
  );
}
```

- [ ] Remove unused CollectorEvent import/usage from this file

---

### Task 2: Strip collector from Android Dart layer

**Files:**
- Delete: collector_manager/page/events/status/permissions.dart, database/collector_repository.dart
- Modify: main.dart, sync_manager.dart, models.dart, clipboard_manager.dart, app_database.dart, legacy_migration.dart, notification_health_monitor.dart, app_localizations.dart

- [ ] Remove CollectorManager init, collector Tab, collector settings from main.dart; keep NotificationSyncPage reachable via existing notification entry
- [ ] Remove broadcastCollectorEvent + collector/event handling + collector_repository import from sync_manager.dart
- [ ] Remove CollectorEvent / CollectorCategories / toCollectorPayload from models.dart
- [ ] Remove collectorClipboardOnly and CollectorManager references from clipboard_manager.dart
- [ ] Remove collector_events table/migration import
- [ ] notification_health_monitor: depend only on NotificationManager.isEnabled
- [ ] Remove collector localization strings

---

### Task 3: Strip collector from Android native layer

**Files:**
- Delete Kotlin collector/SMS/call files + BootReceiver if only for collector
- Modify: AndroidManifest.xml, MainActivity.kt

- [ ] Remove SMS/phone/call-log permissions and CollectorForegroundService
- [ ] Remove collector MethodChannel / service start-stop / CollectorEventBridge from MainActivity

---

### Task 4: Strip collector from macOS

**Files:**
- Delete DeviceCollector* + CollectorWindow + CollectorView
- Modify: SyncManager, MenuController, PreferencesManager, SettingsView, Localization, AppDatabase

- [ ] Remove collector/event case
- [ ] Remove phone collector menu item/window
- [ ] Remove collector prefs + settings toggles
- [ ] Remove collector localization keys
- [ ] Remove collector_events table creation/migration

---

### Task 5: Docs + context

- [ ] Update README.md / AGENTS.md collector mentions
- [ ] Update Kim_AGENTS.md with completion timestamp

---

## Spec coverage

| Spec item | Task |
|-----------|------|
| notification/post decoupling | 1 |
| Android collector delete | 2, 3 |
| macOS collector delete | 4 |
| Keep notification sync UI | 2, 4 |
| Docs | 5 |
