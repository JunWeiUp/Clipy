# Dual Sync Auth Switches Implementation Plan

> **For agentic workers:** Implement task-by-task. Steps use checkbox syntax.

**Goal:** Split peer authorization into clipboard vs notification outbound toggles; keep offline notification queue filtered by notification auth.

**Architecture:** Two peer-id lists in prefs; SyncManager fanout selects list by message kind; UI shows two switches per device. Migrate by copying legacy `authorizedPeerIds` into both lists.

**Tech Stack:** Swift/AppKit prefs + SyncManager; Flutter SharedPreferences + SyncManager + Settings UI.

## Task 1: macOS PreferencesManager

- Add `clipboardSyncPeerIds` / `notificationSyncPeerIds`
- One-shot migrate from `authorizedPeerIds`
- Keep `authorizedPeerIds` as union getter; setters for dual lists update union for stale UI

## Task 2: macOS SyncManager + Settings UI

- Fanout history → clipboard list; notif.* → notification list
- Settings: two toggles per peer; stale = union

## Task 3: Android SyncManager + prefs

- Same dual lists + migrate
- `_fanout` / pending enqueue / flush gated by kind
- `setClipboardSyncTarget` / `setNotificationSyncTarget`

## Task 4: Android UI + l10n

- Two switches per peer; update hints on Android + macOS Localization
