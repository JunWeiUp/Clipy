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
| `history` | both | Clipboard history item (encrypted payload) |
| `history.fetch` | requester → peer | Ask peer to replay recent text history |
| `ack` | receiver → sender | History (reliable) delivery ack |
| `notif.post` / `notif.dismiss` / `notif.clear` | both | Notification mirror |
| `notif.ack` | receiver → sender | Notification delivery ack |
| `notif.config` | — | Reserved; receivers ignore |
| `ping` / `pong` | both | Keepalive |

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

- Scan local `/24` for TCP **5566** + optional manual `IP:port`.
- Endpoint cache key: `clipy.peerEndpoints.v2` (SharedPreferences / UserDefaults), TTL 24h.
- User **refresh** prunes the disk cache to **live sessions only** (offline ghosts are forgotten across restart).
- On sync **start**, cache is used only to **dial** known hosts; peers appear in the LAN device list after handshake succeeds (not pre-filled from cache).
- Connectivity / path changes may re-trigger discovery (debounced).

## Session

- After hello/welcome, one session per `peerId`.
- **Client role**: lexicographically smaller `peerId` owns reconnect on pong timeout / EOF (avoids dual redial storms).
- Duplicate inbound/outbound for same peer: **replace** the old session (do not silently drop the new one).
- Authorization: outbound fanout only to peers in clipboard / notification allow-lists. Mac also gates inbound with the union of authorized ids.

## Reliability

### History

1. Sender fans out `history` and tracks in-flight / pending until `ack` with matching `hash` (ACK clears by **peer + hash**).
2. Receiver must **persist successfully, then send `ack`**. Never ack before store (headless Android previously hung on DB → no ack).
3. Both ends: SQLite `pending_sync` stores **encoded frames** keyed by `(peer_id, hash)`; ≥**120s** without ack clears in-flight and re-flushes on the ping path (Mac; avoids catch-up storms).
4. Android may still flush legacy `pending_text_sync` (plaintext) once, re-encoding into `pending_sync`. `NotificationManager` keeps its own notif pending table for content-level offline queue.
5. **`history.fetch`**: sent on session up / catch-up (Android **request** throttle **15 min**). **Not** on every FGS `syncTick`. Both ends **respond** with up to ~200 recent text entries; Mac **response** throttle **15 min** (Android respond throttle remains 30s). Fetch replay is **not** enqueued into `pending_sync`; receivers still ACK each `history` frame, but Mac only logs `cleared pending` when a real pending row was deleted.

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

## Remaining asymmetry

| Topic | Notes |
|-------|--------|
| File transfer | Stub on both ends |
| Notif offline queue | Android still has `pending_notification_sync` (content JSON) in addition to encoded `pending_sync` |
| Inbound auth | Mac gates inbound with authorized union; Android is looser |

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
