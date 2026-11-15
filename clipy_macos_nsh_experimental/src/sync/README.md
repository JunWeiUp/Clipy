# Fresh LAN v3 implementation

`host/macos/Sources/ClipyNative/LANService.swift` implements manual TCP listening/dialing,
v3 handshakes, AES-GCM text payloads, peer+hash receipts, framing limits and bounded
inbound admission. It uses the isolated experiment identity and default port 5567.
Explicit refresh scans up to two physical en-interface /24 networks with 16 concurrent
800 ms handshakes. Authorization gates automatic history and notification fanout.
Encrypted offline frames are journaled before send; restoration, retry, ownership
locking and ACK cleanup use a 16 MiB / 2048-record limit. This new store uses files,
not the production SQLite pending table. Manual connections can reach cross-subnet IPs.
File transfer streams 1 MiB AES-GCM chunks, verifies SHA-256 and publishes atomically;
folders use bounded ZIP stored snapshots and validated extraction (512 MiB including
ZIP overhead, 10,000 entries, no links/traversal/aliases). Hidden/empty entries and
executable bits survive a roundtrip; same names receive a numeric suffix.

The TypeScript owner must persist `lan.history.received` before calling
`lan.ack({messageId})`. A storage rejection must leave the message unacknowledged.
Disconnect rejects outstanding sends; timeout is unconfirmed, never successful.
A 30-second maintenance task runs only while synchronization is started; it sends
pings and retries stale pending frames. Stop cancels it and all retry/scan tasks.

Protocol contract sources: `docs/PROTOCOL.md`; minimal codec-only inspection of the
existing SyncManager's history-fetch encoder establishes that history's decrypted
payload is raw UTF-8 text, not a JSON object. ClipboardManager's content-hash function
establishes trim + CRLF/CR normalization followed by SHA-256. No legacy transport or
UI implementation is copied.

Run the independent real-socket test from the repository root:

```sh
proxy
swiftc -parse-as-library clipy_macos_nsh_experimental/src/sync/LANRegression.swift \
  clipy_macos_nsh_experimental/host/macos/Sources/ClipyNative/LANService.swift \
  clipy_macos_nsh_experimental/host/macos/Sources/ClipyNative/LANPendingStore.swift \
  clipy_macos_nsh_experimental/host/macos/Sources/ClipyNative/FolderTransferService.swift \
  -o /tmp/clipy-lan-regression
/tmp/clipy-lan-regression
```

The test binds only loopback test ports 15567/15568, uses two independent peer IDs,
sends UTF-8 text both ways, withholds ACK to prove no early success, writes the received
text atomically, then ACKs and checks the confirmed receipt. This is real transport
verification, not evidence that an existing installed client has been tested.

The regression additionally verifies a 3 MiB+17-byte file and a reverse empty file,
withholds application ACK, restores an encrypted pending frame after transport owner
recreation, automatically reconnects and checks notification ACK persistence. Test
state and receive directories are isolated temporary paths and cleaned on completion.
The NativeService bridge must receive stateDirectory and receiveDirectory under its
isolated application root.

Common-relay exposes openTunnel/feedTunnel/closeTunnel to reuse the same framing,
AES, file and ACK owners. RelayStream must split outgoing bytes into SDK-sized blocks.
This API does not create an alternative relay message protocol.

ScreenWireRegression.swift tests only mock screen-control handlers over encrypted
v3 frames: one-use 120-second challenges, peer/session binding, no request-as-success,
unlock-only cooldown and disabled-state rejection. It never locks the real machine.

HistoryStorageRegression.swift exercises native SQLite snapshots over 5 MiB,
Keychain AES-GCM migration/restart, encrypted streaming media, explicit preview
leases, a short-lived Vision OCR worker, cancellation and encrypted OCR search.
Set CLIPY_STORAGE_TEST=1 for its isolated-key cleanup. storage_stdio_regression.py
additionally verifies the production helper with 5,700,000 UTF-8 bytes over bounded
64 KiB chunk requests; the largest generated JSON line is under 90 KiB.

## Reproduce all independent native regressions

Run in the repository root with Bash after the required local `proxy` command.
These generated fixtures do not read the production history or credentials.

```bash
proxy
lan_sources=(
  clipy_macos_nsh_experimental/host/macos/Sources/ClipyNative/LANService.swift
  clipy_macos_nsh_experimental/host/macos/Sources/ClipyNative/LANPendingStore.swift
  clipy_macos_nsh_experimental/host/macos/Sources/ClipyNative/FolderTransferService.swift
)
for probe in LANRegression TunnelRegression ScreenWireRegression SessionArbitrationRegression TransportLifecycleRegression; do
  swiftc -parse-as-library "clipy_macos_nsh_experimental/src/sync/$probe.swift" "${lan_sources[@]}" -o "/tmp/clipy-$probe"
  "/tmp/clipy-$probe"
done
swiftc -parse-as-library clipy_macos_nsh_experimental/src/sync/HistoryStorageRegression.swift \
  clipy_macos_nsh_experimental/host/macos/Sources/ClipyNative/HistoryStorageService.swift \
  -o /tmp/clipy-HistoryStorageRegression
CLIPY_STORAGE_TEST=1 /tmp/clipy-HistoryStorageRegression
swiftc -parse-as-library clipy_macos_nsh_experimental/src/sync/ScreenshotSelectorRegression.swift \
  clipy_macos_nsh_experimental/host/macos/Sources/ClipyNative/NativeScreenshotSelector.swift \
  -o /tmp/clipy-ScreenshotSelectorRegression
/tmp/clipy-ScreenshotSelectorRegression
swiftc -parse-as-library clipy_macos_nsh_experimental/src/sync/DiagnosticsRegression.swift \
  clipy_macos_nsh_experimental/host/macos/Sources/ClipyNative/DiagnosticsService.swift \
  -o /tmp/clipy-DiagnosticsRegression
/tmp/clipy-DiagnosticsRegression
swiftc -parse-as-library clipy_macos_nsh_experimental/src/sync/AppCatalogRegression.swift \
  clipy_macos_nsh_experimental/host/macos/Sources/ClipyNative/AppCatalogService.swift \
  -o /tmp/clipy-AppCatalogRegression
/tmp/clipy-AppCatalogRegression
```

Production-helper stdio and real macOS NSH adapter probes (the second opens its own
small, separate app identity and quits automatically; it never opens the main client):

```bash
proxy
native_helper="$(bash clipy_macos_nsh_experimental/scripts/build_native.sh)"
python3 clipy_macos_nsh_experimental/src/sync/storage_stdio_regression.py "$native_helper"
PATH="$(dirname "$native_helper"):$PATH" CLIPY_NSH_HELPER=clipy-native \
  nsh run clipy_macos_nsh_experimental/src/sync/StorageAdapterProbe.tsx --target macos \
  --name 'Clipy Storage Probe' --port 18990
```

The NSH probe reports `STORAGE_ADAPTER_PROOF` and writes the same JSON under its own
`dev.clipy.tsx.storage-probe` data directory. Successful evidence is 6,006,115 UTF-8
bytes, forty restored history rows and durable delete/undo. Headless test-file contexts
do not expose native filesystem/process capabilities, so this probe runs in a real
macOS runtime instead of pretending a mocked bridge proves native integration.

EditorPressureRegression.swift exercises the pure editor-visible pressure gate,
0...1/tilt bounds, 60 Hz admission, invalid floats and shutdown. It does not prove
physical stylus/Force Touch hardware. Compile it with EditorInputService.swift.
No keyboard event masks or text values are observed by that service.

```bash
proxy
swiftc -parse-as-library clipy_macos_nsh_experimental/src/sync/EditorPressureRegression.swift \
  clipy_macos_nsh_experimental/host/macos/Sources/ClipyNative/EditorInputService.swift \
  -o /tmp/clipy-EditorPressureRegression
/tmp/clipy-EditorPressureRegression
```

Managed-source cleanup also accepts the helper-owned `edited-images/` and
`processed/` directories, in addition to `clipboard/`, `captures/` and `imports/`.
Deletion still requires a durable media record, matching source SHA-256 and an
actually authenticated/verified managed copy; external or changed sources remain.

SessionArbitrationRegression.swift repeats actual simultaneous bidirectional TCP
dials ten times and re-dials while a receipt waits. It verifies stable peer-ID roles,
LAN preference over a warm relay route, pending replay/ACK through relay after LAN
loss, and separation of text/file receipts even when both have the same SHA-256.
File send timers renew on completed bounded writes: idle/final-ACK timeout 120 seconds,
absolute transfer limit 30 minutes. No entire-file JS buffer or unbounded queue is added.

Transport lifecycle is independent: `start` restarts only the TCP listener/routes,
`stopLAN` closes only TCP and cancels LAN discovery/reconnect, while `stopAll` is
reserved for helper shutdown. A relay-only session keeps maintenance and pending
retry active without enabling any LAN dial/scan. The final relay close stops that
maintenance task. TransportLifecycleRegression verifies relay-only stale retry and
ACK cleanup, LAN enable/disable while relay holds the same receipt, and full shutdown.
