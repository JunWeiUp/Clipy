# Native relay integration

This module ports Clipy's current relay behavior. The SDK snapshot comes from
`JunWeiUp/common-relay` commit `794a2396266ee6f26ab7406f6d6466732a269dbf`;
`relay/sdk/SOURCE.json` records upstream hashes and Android adaptations.
The original Java storage implementation from `flutter_secure_storage` 10.0.0
is reused without its Flutter plugin or any engine/channel dependency.
Licenses are also packaged under `assets/licenses/`.

## Application boundary

`NativeRelayController(context, ownerScope, local, hasSession, tryLan, onSocket)`
exposes `state: StateFlow<RelayUiState>` and `start`, `stop`, `refresh`,
`ensurePeer`, `networkChanged`. `state.control` is `RelayControl`.

- The main sync owner calls start/stop with the existing sync lifecycle.
- Settings changes rebuild only the relay connection; they do not change the
  LAN peer ID, built-in LAN key, LAN listener or sharing authorization lists.
- `onSocket(peerId, "relay:<device>", socket, inbound)` hands the main owner a
  normal byte stream, which must run the existing v3 hello/welcome and ACK/file
  machinery. The bridge starts pumping before awaiting adoption to avoid a
  handshake deadlock. LAN discovery is attempted first, at most two private IPv4
  addresses from authenticated presence. Presence has the existing stable LAN ID.
- Control reconnect is bounded to 1–30 seconds, roster requests time out after
  three seconds, and online presence refresh follows the existing 30-second
  cadence. Stop closes sockets/streams and cancels retries. Group invitation
  polling exists only while the page is open and the app is foregrounded.
- Each SDK stream has eight unacknowledged records and sixteen queued inbound
  records. Application v3 frames are transported unchanged. Closed native
  secretstream state is wiped and freed, and cannot be used again.

## Credentials and membership

The adapter preserves existing encrypted preferences, keystore aliases and
private record names. `resetOnError` is explicitly false. Decryption failures
are errors, never instructions to remove credentials or generate a new identity.
When only the separate identity record is absent, a valid stored enrollment's
matching keypair is recovered before considering fresh generation.

Membership comes only from pinned/continuously verified signed entries.
Plain relay rosters and `group.changed` messages are not trust proofs. The SDK
implements manual approval, default ordinary membership, automatic delegated
admission, encrypted compact invitation links, rename/remove/leave/disband,
and strict signed payload validation. Android's permissive Base64 decoder is
wrapped with canonical encoding checks before signed payloads are parsed.

## UI and validation

`RelaySettingsPanel` and `RelayGroupPage` use the original labels, layout tokens,
explicit-save behavior and private pending drafts. `RelayScannerActivity` uses
an app-style bar plus a full camera preview and accepts invitation links only.
The root owner must register the scanner Activity and camera capability.

`RelaySdkVectorsTest` consumes upstream Python-produced box/secretstream,
member-chain, auto-delegation and invitation-link vectors. `RelaySecureStorageTest`
uses isolated preference names and RSA aliases, including corrupted ciphertext
preservation. `RelayLiveInteropTest` requires an isolated server and the explicit
instrumentation argument `relayTestUrl`; without it the test is skipped. It
creates temporary test actors/groups, exercises group operations, then carries
a 1MiB Clipy v3 encrypted message and ACK through actual SDK streams.

`RelayJournalCompatibilityTest` reads fixtures exported by the current Dart SDK
with `clipy_android/tool/export_native_relay_journal.dart`. The native journal
keeps the existing directory, JSON fields and canonical tuple hashes, including
unescaped `/` in scope names. Pending ciphertext and incoming receipts remain
readable after upgrade; completed entries are not sent again. Journal migration
never clears credential records.

API24 adaptations avoid java.nio.file and java.util.Base64. The libsodium
`size_t` state-size return uses JNA NativeLong for Android arm32/arm64; other
length parameters are C unsigned long long and retain Java long. Both native
ABIs are packaged by lazysodium-android; arm32 must not be claimed tested solely
from arm64 emulator results. Release shrinking must keep the JNA Sodium interface
method names and JNA reflection/native entries.

## Isolated UI integration server

Only a debuggable `com.clipyclone.clipy_android.nativepreview` package permits
`ws://127.0.0.1:<port>/relay/v1/ws` for local fixtures. The port must be 1–65535;
userinfo, query, fragment, encoded/alternate paths and other cleartext hosts are
rejected. This is not a product setting or a release fallback. `RelayEndpointPolicyTest`
checks the package/build/URL gate; SDK constructors independently enforce their
loopback-only test mode. Production remains WSS-only. An emulator adb reverse can
connect this isolated fixture to a host test server without touching real enrollments.
