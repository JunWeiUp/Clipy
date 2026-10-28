# Native platform migration

See the live [Android parity checklist](NATIVE_MIGRATION_PARITY.md) for source mapping, implementation coverage and acceptance evidence.

## Required equivalence (user requirement)

This is an implementation-language migration, not a redesign or a reduced client.
Preserve **all existing functionality, UI and interaction behavior** on each
platform. The shipping app is the acceptance baseline; Flutter/Dart is replaced
by native implementation code only.

- Match every screen, navigation entry, text, icon, color, typography, spacing,
  corner radius, theme, dialog, sheet, empty/loading/error state and animation.
  Native framework default styling is not a substitute for the existing design.
- Match tap/long-press/back, search and filtering, scrolling, clipboard behavior,
  permission handling, notifications, sharing, background sync and failure/retry
  flows. No placeholder controls, omitted features or changed workflows count
  as completed migration.
- Retain data, settings, device identity, credentials, installed package identity,
  permissions and protocol interoperability through the eventual upgrade.
- Validate side-by-side with identical synthetic fixtures, viewport, font scale,
  language and appearance. Compare UI captures and execute the same behavior
  scenarios in both implementations, including restart and failure paths.
- A replacement build is ready for phone acceptance only after the full parity
  matrix passes. Never describe a storage/core prototype as an equivalent app.

The initial simplified native history spike has been replaced by the integrated
four-route application. History, devices, notifications, settings, sharing, relay
and platform services now have native implementations. Implementation and passing
component tests do not by themselves establish complete visual or upgrade parity.

## Decision and current boundary

Equivalently port Android to Kotlin/Jetpack Compose, then the iOS main app to Swift/SwiftUI,
then Windows to C#/WinUI 3. macOS already uses Swift/AppKit/SwiftUI. The goal is
simpler system integration and ownership of background work, not elimination of
all build caches. No package-size or memory improvement is claimed before parity
benchmarks. Shared wire fixtures and behavior tests replace shared Dart runtime code.

`clipy_android_native/` is an independent Gradle/Compose application with **no
Flutter build plugin or engine**. Its application-owned native managers connect
the UI to LAN v3, relay, persistent history, files, notification collection and
background services. Acceptance builds use the isolated `.nativepreview` ID and
do not access the production application's data. Android local acceptance and
the same-ID phone upgrade are now complete. This is a local installation, not a
new public Release; iOS/Windows migration and their current builds are unchanged.

## Latest protocol policy

All native/platform implementations target the current repository protocol: LAN v3
and the current relay SDK contract. No v1/v2 wire fallback or protocol downgrade
is required. This does not authorize deleting local history, settings or identity.
Optional v3 capabilities remain part of the current contract: macOS currently
does not advertise `peer-id-v1`, so its v3 session behavior must still interoperate.

## Compatibility contracts

- Production cutover must retain `com.clipyclone.clipy_android`, the release signing
  certificate, and a versionCode greater than the actual installed APK. Existing
  Flutter split-per-ABI builds add ABI offsets; comparing only pubspec is unsafe.
  Preview versions read the same source metadata but are not upgrade candidates.
- Native SQLite uses `filesDir/clipy.db`, schema 6, the same columns/indexes and
  milliseconds timestamps as `lib/database/app_database.dart`. Schema versions
  1–5 upgrade transactionally; newer versions fail rather than deleting data.
  `NativeLegacyMigration` imports pre-SQLite history, notification JSONL and
  file-history preferences with transactional retry/journaling. Legacy, malformed
  input and retry fixtures pass; the actual phone upgrade also retained existing
  rows, files, stable preferences, identity and permissions.
  No silent empty-database fallback is allowed.
- Text hashes use Dart-compatible whitespace trim, CRLF/CR normalization and
  UTF-8 SHA-256. Recopy deletes/reinserts atomically; failed inserts preserve the
  original. Catch-up replay uses insert-ignore instead of recopy.
- Preserve all `FlutterSharedPreferences` keys, stable device IDs, saved peers,
  pending queues and timer state. Secure-storage relay credentials must migrate
  on-device through their existing keystore format, never through plaintext logs.
- Freeze LAN v3 framing, AES-GCM/default key, roles, ACK-after-commit, fetch
  throttling and file chunk/window behavior. Keep macOS interoperability tests.
- Relay includes identity, encryption, membership, invitations/delegations,
  short links and reconnect behavior; LAN-only support is not feature parity.
- Notifications, downloads, foreground services, watchdogs, boot handling,
  permission state and timer widgets must survive upgrades. Reuse proven Kotlin
  system adapters after removing their MethodChannel dependencies.

## Delivery status

| Stage | Status | Evidence / scope |
| --- | --- | --- |
| Android native history | Locally accepted | Repository/behavior tests and real-reference UI flows; existing phone history retained |
| Android settings and storage migration | Locally accepted | v1–6/legacy/secure-storage fixtures and actual phone before/after comparison |
| Android LAN core | Locally accepted | Protocol/retry/file tests, automatic Mac-to-phone receive proof, user-tested phone sending |
| Android relay | Locally accepted with known clock limitation | SDK/storage/journal/live-server/16KiB tests; phone identity retained; manual-clock invitation rule documented below |
| Android platform/UI parity | Locally accepted | Real Main/reference flows, notifications, sharing, timer and emulator lifecycle/Doze evidence; user phone acceptance |
| Android production cutover | Complete locally | Original ID/certificate, 14284→14285, UID and data/key/permission continuity verified |
| iOS native main app | Pending | Existing main-app migration plan and builds unchanged |
| Windows native app | Pending | Existing native migration plan and builds unchanged |
| Remove Flutter | Pending | Other shipping platforms and reference tooling still require Flutter |

Do not infer a public release from this local cutover or remove Flutter while
other shipping platforms still depend on it.

## Ownership and bounded resources

`ClipyDatabase` and the repositories own schema compatibility, transactional writes
and SQL filtering before pagination. `HistoryViewModel` serializes IO and rejects
stale search results. `NativeSyncManager` owns the transport, discovery, ACK waits
and retries; Application/FGS/WorkManager/Boot retain the original lifecycle roles.
`NativeNotificationManager` owns persistent notification queues and event-driven
collection; its health timer runs only with the UI foregrounded. Incoming shares
retain bounded staging and explicit cancellation/cleanup. No Flutter engine or
MethodChannel is needed by these paths.

Text input remains bounded to 1MiB. Long-document inspection preserves full text
and selection through bounded virtual layouts instead of laying out hundreds of
thousands of lines at once. Socket, file, notification and retry bounds are listed
in the [parity checklist](NATIVE_MIGRATION_PARITY.md) and owning modules. Media and
file operations are integrated; physical-device receive checks and user-tested
sending/sharing are recorded below.

## Verification and next step

See [native Android build instructions](../clipy_android_native/README.md).
The schema asset is a snapshot of the shipping v6 creation SQL. `scripts/check_native_android_schema.py`, included in the repository gate,
compares its tables and indexes with the shipping Dart creation SQL. Keep the
upgrade fixtures aligned for any future schema change. Instrumentation fixtures are synthetic and use unique cache paths.
Test fresh installs, every supported schema version, rejected future versions,
failed recopy rollback, literal wildcard search and deterministic ordering.

The consolidated API26 and API37 runs each report 77 tests: 74 execute and pass;
three opt-in cold/share/diagnostics UI scenarios are covered by independent runs.
Build, unit tests and Lint pass. See the parity checklist for the scenario-level
limits; sampled UI checks do not imply every device/font/theme combination was
exhaustively tested. Android local acceptance is complete. iOS/Windows and any
future public distribution remain separate work.

## Completed phone upgrade and acceptance

The phone was upgraded in place from Flutter 14284 to native 14285 using the
original `com.clipyclone.clipy_android` ID and release certificate. UID 10418
was retained. `/tmp/clipy-phone-cutover-verification.json` verifies retention of
all existing history/notification/file-transfer rows, received-file hashes,
stable preferences and identity, Keystore aliases/certificates, permission grants,
notification access, widget count, backup eligibility, battery exemption and
exact-alarm state. Two normal dynamic configuration/cache fields were distinguished
from identity and stable preferences; they are not claimed to be byte-identical.
Private backups and user content are not published in these documents.

Automatic Mac-to-phone verification found exactly one matching text row by its
hash and a 2,816-byte received file with the expected SHA-256
(`/tmp/clipy-phone-live-receive-proof.json`). The user separately confirmed Android
text sending, file sending and sharing work. That reverse-direction/share
acceptance is user testing: the specific `PHONE_TO_MAC` automated marker was not
found, so no automated marker success is claimed.

The user chose to retain manual system time. The shared relay SDK rejects an
automatic invitation when the handset is approximately 41 seconds ahead of the
test server; the old Dart client applies the same rule. This is an accepted
existing environment limitation, not a native-migration regression or a request
to change the user's clock.

Phone test/preview/probe APKs have been removed and the installed production app
has been opened. Temporary test servers and the additional test emulator were
stopped. This completion does not change public Release status.

## Supporting emulator and runtime evidence

The earlier API26 synthetic 14284→14285 upgrade retained one fixture history row,
all existing preferences and its UID (`/tmp/clipy-signed-upgrade-emulator-proof.json`).
That limited rehearsal is separate from the completed real-phone checks above.
API37 reported `PAGE_SIZE=16384` and eight passing relay tests without skips,
including real-server run `33ad7499` (`/tmp/clipy-native-relay-16k-final.txt`). Both
native-library alignment and actual 16KiB crypto execution were verified.
