# Clipy LAN Sync Protocol v2

Canonical wire + reliability notes for macOS (`Sources/Sync/`) and Android Dart (`lib/sync/` + `sync_manager.dart`).  
Do **not** change framing/crypto without bumping `v` and updating both ends plus this doc.

## Framing

- Transport: raw TCP, default port **5566**.
- Each frame: **4-byte big-endian length** + UTF-8 JSON body.
- Max frame: **2 MiB**. Handshake frames should stay ≤ **64 KiB**.
- Envelope fields (`v: 2`):

| Field | Type | Notes |
|-------|------|--------|
| `v` | int | Must be `2` |
| `type` | string | See message types |
| `msgId` | string | UUID |
| `peerId` | string | Stable device id |
| `name` | string? | Display name (hello/welcome) |
| `port` | int? | Listen port (hello/welcome) |
| `ts` | number | Unix seconds |
| `hash` | string? | Content / notif hash for ack |
| `payload` | string? | Base64(AES-GCM blob) when encrypted |

## Message types

| type | Direction | Purpose |
|------|-----------|---------|
| `hello` / `welcome` | both | Handshake |
| `history` | both | Clipboard history item (encrypted payload). Outbound only to clipboard allow-list; inbound accepted without reciprocal auth |
| `history.direct` | both | Device-list one-shot text send (same payload as `history`); no allow-list; dial reason `direct` |
| `history.fetch` | requester → peer | Ask peer to replay recent text history; peer responds only if requester ∈ its clipboard allow-list |
| `ack` | receiver → sender | History (reliable) delivery ack |
| `notif.post` / `notif.dismiss` / `notif.clear` | both | Notification mirror |
| `notif.ack` | receiver → sender | Notification delivery ack |
| `notif.config` | — | Reserved; receivers ignore |
| `ping` / `pong` | both | Keepalive |
| `file.meta` | sender → receiver | Chunked file transfer header. Encrypted payload = JSON `{fileId, name, size, chunkSize, chunks, sha256}`; envelope `hash` = file sha256 |
| `file.chunk` | sender → receiver | Encrypted payload = `u32 BE chunk index ‖ raw bytes`; envelope `msgId` = fileId (deterministic, for routing). chunkSize is sender-chosen (1 MiB recommended; receivers accept any size that keeps the frame < 2 MiB) |
| `file.ack` | receiver → sender | Encrypted payload = JSON `{fileId, ok, error?}`. `ok=false` errors: `tooLarge / ioError / hashMismatch` |

API-layer aliases on Android (`notification/post`, …) map to `notif.*` before send.

## Crypto

- Payload ciphertext: **AES-GCM-256**, wire form `base64(nonce12 ‖ ciphertext ‖ tag)`.
- Empty user pairing secret → legacy key `SHA256("ClipySyncSecret2026")` (compat only).
- Non-empty pairing secret → **HKDF-SHA256**:
  - salt: `clipy.sync.v2.hkdf`
  - info: `aes-256-gcm`
  - length: 32
- Parity tests: `clipy_android/test/hkdf_parity_test.dart`, `sync_crypto_test.dart`.

## Discovery

- **Proactive dial vs scan**
  - Only a user **refresh / scan devices** action may dial arbitrary `/24` hosts (`reason=scan`).
  - Device-list **Send Text / Send File** dials with `reason=direct` (no auth) and uses `history.direct` (text) / `file.*` (files).
  - All other outbound dials (`cache`, `reconnect`, `deliver`, `manual`, `syncTick`, startup) require the target `peerId` ∈ authorized set (clipboard ∪ notification). Unauthorized cache entries are not dialed. Reconnect may use `direct` when pending `history.direct` frames exist for that peer.
  - Inbound connections still accepted. Auth is **one-sided (sender)**: allow-lists gate outbound fanout / `history.fetch` responses / proactive dial; receivers accept inbound `history` / `history.direct` / notif without reciprocal authorization.
- Endpoint cache key: `clipy.peerEndpoints.v2` (SharedPreferences / UserDefaults), TTL 24h.
- User **refresh** prunes disk cache to **live sessions ∪ still-authorized** peers (drops unauthorized ghosts). Settings/open must **not** prune or full-scan.
- On sync **start** / network restore: dial **authorized** cache only; peers appear in the LAN list after handshake (not pre-filled from cache).
- Settings **authorized devices** UI lists authorized peers even when offline (labels from cache), plus currently discovered peers for new checkboxes.

## Session

- After hello/welcome, one session per `peerId`.
- **Client role**: lexicographically smaller `peerId` owns reconnect on pong timeout / EOF (avoids dual redial storms).
- Duplicate inbound/outbound for same peer: **replace** the old session (do not silently drop the new one).
- Authorization: **one-sided**. Outbound fanout / proactive dial / `history.fetch` responses use clipboard or notification allow-lists on the sending device. Receivers accept inbound history and notifications without requiring the sender on their allow-list. Device-list `history.direct` needs no allow-list on either side.

## Reliability

### File transfer

1. Interactive one-shot over the live session: sender waits/dials `direct` for a session (≤8s), streams the file in 512 KiB chunks (`file.meta` first, then `file.chunk`s), and waits for `file.ack`. **Nothing is enqueued into `pending_sync`** — a dropped session fails the transfer; the user retries.
2. Each attempt uses a fresh `fileId`; chunks carry `msgId = fileId` so concurrent transfers from one peer stay routed.
3. Receiver: append-only `.part` file next to the final destination (same volume → atomic rename), idle timeout **120s** (no chunk) discards state, size cap **512 MiB** (rejected via `file.ack tooLarge`), full-file sha256 verified before promote; sender aborts mid-stream when a reject ack lands.
4. Delivery: Android saves into `<appStorage>/Clipy/` + `file_transfers` row (20-row trim also deletes managed files); macOS moves into `~/Downloads/Clipy/`, inserts a `.files` history entry (no clipboard write), posts a system notification.
5. macOS chunk writes are pipelined through `syncQueue.async` (bounded: 8 frames in flight), guarded by a retired-fd set; session sockets carry 4 MiB `SO_SNDBUF`/`SO_RCVBUF` and the read loop drains until EAGAIN.
6. Throughput notes: pure-Dart AES-GCM measured ~2 MB/s (desktop) / <1 MB/s (phone) — Android routes file-chunk crypto through the native `sync_crypto` MethodChannel (javax.crypto, ARMv8 crypto extensions) with a pure-Dart fallback; Mac uses CryptoKit. Both senders pipeline encrypt + network I/O (Android: bounded 4 MiB in-flight instead of per-chunk flush). Wire cost is base64 (+33%); text/history frames are unaffected.

### History

1. Sender fans out `history` and tracks in-flight / pending until `ack` with matching `hash` (ACK clears by **peer + hash**).
2. Receiver must **persist successfully, then send `ack`**. Never ack before store (headless Android previously hung on DB → no ack).
3. Both ends: SQLite `pending_sync` stores **encoded frames** keyed by `(peer_id, hash)`; ≥**120s** without ack clears in-flight and re-flushes on the ping path (Mac; avoids catch-up storms).
4. Android may still flush legacy `pending_text_sync` (plaintext) once, re-encoding into `pending_sync`. `NotificationManager` keeps its own notif pending table for content-level offline queue.
5. **`history.fetch`**: sent on session up / catch-up (Android **request** throttle **15 min**). **Not** on every FGS `syncTick`. Both ends **respond** with up to ~200 recent text entries; Mac **response** throttle **15 min** (Android respond throttle remains 30s). Fetch replay is **not** enqueued into `pending_sync`; receivers still ACK each `history` frame, but Mac only logs `cleared pending` when a real pending row was deleted. Android coalesces the fetch response into `handleRemoteSyncBatch` (hash dedup): **no system clipboard write when every hash already exists**; if any new rows insert, only the newest new text is written. Live single-frame `history` still uses `handleRemoteSync`, which also skips clipboard when the hash is already the local latest.

### Notifications

1. Outbound `notif.post` (etc.) wait for `notif.ack` where applicable.
2. Android NLS → Dart MethodChannel → `NotificationManager` → `broadcastNotificationMessage`.
3. Headless: Application must attach NLS channel; buffered posts live in `NativePendingPostStore` until drained.

## Headless Android (process death / boot)

Required MethodChannel registration on the **cached Application FlutterEngine** (not only MainActivity):

| Channel | Purpose |
|---------|---------|
| `…/storage` | App DB paths (`StoragePaths`) — missing → history never acks |
| `…/clipboard` | Native `setText` + FGS drain prefs |
| `…/notifications` | NLS → Dart; `drainNativePendingPosts` |
| `…/sync_service` | Start/stop FGS |
| `…/sync_control` | Dart: `ensureSyncStarted` / `syncTick` (returns next delay ms) / `drainNotificationInbox` |

**Forbidden**

- Register `storage` or NLS ownership only in MainActivity.
- `onDestroy` clearing NLS `MethodChannel` while the engine stays alive.

Entry: `ClipyApplication` → `PlatformChannels.registerAll` when sync is enabled (or Activity adopts engine into cache); FGS `START_STICKY` → `ensureEngine` + ticks.

### Android power / FGS

- FGS holds a **timed** `PARTIAL_WAKE_LOCK` (10 min), renewed on `onStartCommand` and each `syncTick` (not an indefinite hold).
- `syncTick` is adaptive: **30s** when reconnect/pending work is needed, **90s** when all authorized peers are connected and idle. Still does **not** send `history.fetch`.
- Subnet scan concurrency **24**; syncTick-triggered full scan min gap **5 min**. Network restore prefers **endpoint cache dial** before `/24` full scan.
- `ClipyApplication.onCreate` warms the FlutterEngine only when `flutter.syncEnabled` is true (same gate as BootReceiver).
- FGS type is **`specialUse`** (Android 14+): Android 15 enforces a **6h/24h quota** on `dataSync`, which used to force-stop the always-on :5566 listener every few hours. API 29-33 falls back to `dataSync`.
- **WorkManager watchdog** (`SyncGuardWorker`, 15 min periodic) re-asserts the FGS after the system kills it (Doze / MIUI) — it survives process death, unlike `START_STICKY` whose delivery Doze often drops. It runs as a **foreground worker** (`specialUse`/`dataSync` `ForegroundInfo`) so launching the FGS is legal under the Android 12+ background-FGS-start restriction. Armed by `ClipyApplication.onCreate` / `startForegroundSyncService` / `BootReceiver`; cancelled by `stopForegroundSyncService`. `onTaskRemoved` also re-asserts the FGS on swipe. Redmi/MIUI still requires the user to grant 自启动 + 省电无限制.

## Remaining asymmetry

| Topic | Notes |
|-------|--------|
| File transfer retransmit | No resume/offset protocol; a dropped session restarts from scratch with a new fileId on retry |
| Notif offline queue | Android still has `pending_notification_sync` (content JSON) in addition to encoded `pending_sync` |
| Inbound auth | None for history/notif/files (one-sided). `history.fetch` response still gated by clipboard allow-list on the responding device |

## Code map

| Concern | Android | macOS |
|---------|---------|-------|
| Envelope / types / framing | `lib/sync/protocol.dart` | `Sync/SyncProtocol.swift` |
| AES-GCM / HKDF | `lib/sync/crypto.dart` | `Sync/SyncCrypto.swift` |
| Subnet / manual / cache | `lib/sync/discovery.dart` | `Sync/SyncDiscovery.swift` |
| Dial / listen / handshake / read loop | `lib/sync/session.dart` | `Sync/SyncTransport.swift` |
| Fanout / pending / ack | `lib/sync/reliability.dart` + `database/pending_sync_repository.dart` | `Sync/SyncReliability.swift` + `PendingSyncRepository.swift` |
| Orchestration + clipboard/notif hooks | `lib/sync_manager.dart` | `Sync/SyncManager.swift` |
| Platform channels / FGS / NLS | `PlatformChannels.kt`, FGS, NLS | — |

## Manual regression

1. Kill Android app → wait FGS/engine → Mac copy text → Android acks without opening UI.
2. Same setup → phone notification → appears on Mac without opening UI.
3. Open Android UI → sync still works (no double-bind on 5566).
4. Steady connected state: Mac log must **not** show `history.fetch … pushing 200` every 30s; repeat fetch within 15 min → `ignored (throttled)`.
5. Session up still allows one catch-up `history.fetch` (request + Mac respond throttle 15 min).
6. Mac offline while Android copies → Mac reconnect → pending encoded frames flush without opening Android UI.
7. Mac sends `history.fetch` → Android pushes recent text (≤200).
8. Connected idle: Android FGS `syncTick` spacing ≈ 90s (not a fixed 30s forever).
9. Sync off + cold start without UI: no warm engine / no FGS; open UI still single engine (no double-bind :5566).
10. Device-list **Send Text** without authorization: `history.direct`. Automatic clipboard/notif: authorize only on the **sending** device; receiving peer does not need to authorize the sender.
11. Device-list **Send File** both directions (Mac ⇄ Android): sender waits for `file.ack`; receiver gets the file on disk (Mac: `~/Downloads/Clipy` + history entry + notification; Android: `Clipy/` + 已接收文件 page) without any authorization toggles.
