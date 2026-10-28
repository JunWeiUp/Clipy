# Android native parity checklist

The acceptance baseline is the current Flutter Android app, not the original
native preview. This checklist does not replace the full contract in
[NATIVE_MIGRATION.md](NATIVE_MIGRATION.md). A row is complete only after its
behavior and same-fixture UI evidence pass. No row is accepted merely because
its code compiles.

Status: **Android local acceptance and the original-ID phone upgrade are complete**.
The installed native build is 14285, signed with the original certificate, with
UID 10418 retained. The user confirmed Android text/file sending and sharing work;
automatic receive and before/after continuity evidence is recorded at the end of
this document. Public Release status and subsequent iOS/Windows work are unchanged.
The matrix records coverage limits, not uncompleted installation blockers. Synthetic
fixtures alone are not acceptance evidence; the real Main flows and phone checks
below distinguish automated verification from user testing.

| Area | Existing source / contract | Native progress | Evidence / coverage limits |
| --- | --- | --- | --- |
| Theme and fonts | `lib/ui/app_theme.dart`, Material fonts | Exported light/dark tokens, platform sans-serif and original Material Icons; real-reference typography fixes | Remaining cross-screen visual combinations; normal/large Chinese text and zero-animation sample are covered |
| Localization | `lib/app_localizations.dart` | Static bilingual getters and dynamic messages ported; runtime locale wired through the host | Final runtime locale/resource-string visual coverage |
| Four-route chrome | `features/history/home_page.dart` | `ClipyShell`: logo, files/menu, 76dp nav, 720dp rail, 920dp content, fade/back | Real destinations/keep-alive integrated; 720dp rail and below-threshold bottom navigation verified, 64dp rail step corrected; remaining multi-state review |
| History list | `ui/clipboard_history_list.dart` | `HistoryPage`: heading, search/chips, dates/cards, pull refresh, long-press sheet | Real image/file-path previews and clear/empty states covered; remaining physical copy/haptics and paging/short-list combinations |
| History storage | `database/clipboard_repository.dart` | v6 schema/upgrades, literal search, recopy rollback, legacy JSON/JSONL/file imports and retry journaling tested; clipboard/UI and remote ACK-after-commit integrated | Actual phone rows/files/stable preferences retained; no exhaustive source-app/filter matrix |
| Clipboard capture | `clipboard_manager.dart`, Kotlin listener | Native foreground/resume listener, explicit copy suppression and remote loopback guard integrated and tested | Physical-device clipboard/resume behavior |
| Clear history | `HomePage._clearHistory` | Real Main confirmation/cancel preserves media; confirmed clear reaches matching empty state on both apps; dialog width corrected and recaptured | Physical-device acceptance and storage-failure UX |
| Settings | `features/settings/mobile_settings_content.dart` | Real UI language/theme changes and new-process persistence verified for Chinese dark and light; normal/large-font reference captures available | Remaining cross-screen locale/theme combinations and physical acceptance |
| Timer widget | Existing Kotlin `Timer*.kt`, resources | Original classes/layouts retained; real launcher pin, start/pause/reset, update continuity and natural expiry notification verified | Remaining wheel/preset variants, reboot and physical permission/OEM acceptance |
| Connection editor | `features/devices/devices_page.dart` | Native sheet and atomic settings store integrated | Name/port validation, save once/restart once, exact sheet |
| Devices and discovery | `device_widgets.dart`, `sync/discovery*` | Native discovery/manager/device UI integrated, including relay route state | Progress/cooldown, saved offline/online order, manual IPv4, per-peer switches |
| LAN v3 transport | `sync/protocol/crypto/session/reliability` | Native codec/AES-GCM/TCP/duplicate arbitration/heartbeat/ACK receipts implemented and loopback-tested; LAN manager, service, discovery and persistent retry integrated; loopback end-to-end tested | Mac→phone exact receive checks passed; phone sending accepted by user; reconnection/lifecycle automation remains emulator evidence |
| File transfer | `sync/file_transfer.dart`, received-files page | Native sender/receiver/store/page/notifications integrated; bidirectional, failures, cleanup and retention tests passed | Physical large-file transfer, Downloads fallback/permissions and final progress UI |
| Incoming Android shares | `SharedFileInbox.kt`, `incoming_share.dart` | Native inbox/staging/review UI integrated; real Main SEND text/multiple content URIs, device roundtrip, partial failure/retry and cleanup verified against Flutter reference | API26 system-navigation color corrected; phone sharing accepted by user; not every locale/font-scale/theme combination sampled |
| Relay identity and sessions | `sync/relay_*`, vendored SDK | Existing Java SDK adapted; cross-language vectors, secure storage, Dart journal and real-server v3 tunnel tested on API26 | Phone identity/Keystore/stable configuration retained; automatic invitations have the existing manual-clock limitation documented below |
| Relay groups and invitations | `relay_group_page.dart`, SDK groups/links | Real Main group creation, automatic/manual invitations, matching pairing-code approval, applicant return/recovery, rename, cancel, leave, revoke cleanup and disband verified with isolated server/Python peer; paired reference onboarding and camera permission/return checked | Remaining theme/font-scale combinations, physical camera and installed-membership continuity |
| Notification collection | NLS + `notification_manager.dart` | Native NLS/manager/UI integrated; real system/ACK/cold-start tests pass; real Main two tabs, app filtering/toggles, permission return and draggable full-text detail compared with Flutter | API26 system-navigation color corrected; physical mirrored-content/OEM/boot acceptance |
| Background service | FGS/Application/Guard/Boot Kotlin adapters | Native Application/FGS/WorkManager/Boot integrated; emulator background ACK, kill-9 START_STICKY/new PID, reboot without Activity and real forced-Doze recovery verified | Physical MIUI/OEM background, reboot/upgrade and permission continuity acceptance |
| Logs | `features/logs/log_page.dart` | Real Main copy success, cancel-retains, confirmed clear and empty states verified against reference; same synthetic log formatting captured | Physical acceptance and additional failure/live-refresh states |
| Diagnostics | `features/devices/sync_diagnostics_page.dart` | Both actual pages update relative times automatically and reset to empty; native opt-in UI driver passes; selectable-text width corrected from Flutter caret rules | Physical diagnostics with real retained peers |
| Upgrade | app ID, certificate, APK versionCode, v1–6 DB, prefs/keystore | Phone 14284→14285 same-ID/same-certificate upgrade complete; UID, original rows/files, stable preferences, identity/Keystore and permission state retained | Two normal dynamic config/cache fields distinguished from stable identity; see cutover proof |
| Final installation | Physical Android device (`adb` target selected explicitly) | Complete locally; production app opened, temporary phone test/preview/probe APKs removed | Mac→phone automatically verified; phone sending/sharing accepted by user; no public Release implied |

## Reproducible design references

`flutter test tool/export_native_theme_test.dart --no-pub` exports the actual
shipping theme into native `assets/ui_tokens.json`; no Flutter runtime is linked
into the native APK. Material Icons are copied from the pinned Flutter SDK with its license. The
reference APK has no Roboto font asset; native body text uses platform sans-serif. Static localized getters are copied
from `AppStrings`, not rewritten or machine-translated.

Debug fixture launch (emulator only while parity is incomplete):

```sh
adb -s "$ANDROID_SERIAL" shell am start -n com.clipyclone.clipy_android.nativepreview/com.clipyclone.nativeandroid.VisualFixtureActivity --es scene history --es language zh --ez dark false
adb -s "$ANDROID_SERIAL" shell am start -n com.clipyclone.clipy_android.nativepreview/com.clipyclone.nativeandroid.VisualFixtureActivity --es scene settings --es language en --ez dark true
```

The fixture activity is absent from release source sets. It uses only fictional
entries and does not connect to peers or read personal data. It is not a product
screen or an alternative acceptance target.

## Native sync ownership

- `sync/NativeLanTransport`: explicit start/stop, at most 128 tracked sockets,
  one reader per session, <=64KiB handshakes and <=2MiB frames. Timers run on the
  default coroutine dispatcher while socket IO uses a bounded elastic view, so
  blocked reads cannot starve the absolute two-second handshake deadline. Stop
  closes sockets before cancelling jobs; duplicate replacement is atomic.
- `SyncProtocol`/`SyncCrypto`: the same v3 fields and AES-GCM blob as current
  Swift/Dart, with no downgrade; fixed shared ciphertext, binary chunks, tamper
  rejection and fragmented/coalesced reads are covered in instrumentation tests.
- `SyncSettingsStore`: stable peer ID, per-peer capabilities, endpoints, manual
  addresses, full-form connection commits; reads both historical Flutter list
  serializations and current JSON-prefixed lists. This is local data migration,
  not support for old network protocols. Unknown preference keys remain intact.
- `PendingSyncRepository`: existing encoded-frame table, peer/hash ACK removal,
  24h expiry and 500-per-peer cap. The Application-owned manager and foreground
  service now wire queue ownership, flush and retry.
- `TextDeliveryReceipts`: 32 concurrent peer/hash waits, shared duplicate sends,
  12-second timeout, matching ACK only, timer cleanup on stop.
- `HistorySyncReceiver`/`SqliteHistorySyncStore`: transactions complete before
  ACK; identical latest text does not rewrite clipboard; fetch replay uses
  insert-ignore and publishes only the newest new text. Catch-up windows have
  2s debounce/8s deadline and the existing 8Mi-character limit. Closing discards
  uncommitted windows and suppresses late ACKs.

The LAN modules, full UI routes, file/notification dispatch and relay are wired
into the native Application/FGS. Loopback and isolated real-server tests are not
a substitute for real-device evidence; the completed phone checks are separately
recorded below.

## Native application/service integration

- `NativeSyncManager` owns one run scope, transport, catch-up receiver, ACK waits,
  discovery and reconnect jobs. Stop invalidates the run before cancelling work.
  The foreground service owns the existing adaptive 30/90-second tick; a mutex
  prevents overlapping ticks when its 60-second watchdog expires.
- Explicit discovery uses 64 workers over at most two eligible /24 networks;
  VPN/mobile interfaces are excluded. Manual and remembered endpoints run first.
  Automatic share refresh has a 30s cooldown, manual refresh 3s, and callers join
  one task. Ordinary startup/ticks probe authorized endpoints only; two failures
  can trigger the existing full-scan fallback with a 10-minute cooldown.
- Pending frames are persisted before writing and in-flight marks are installed
  before a fast ACK can arrive. Flush reads one BLOB at a time after enumerating
  keys, rather than materializing 500 large frames. Reconnect clears marks;
  stale history retries and peer/hash queue removal retain the existing rules.
- `ClipyApplication`, `ClipySyncForegroundService`, `SyncGuardWorker`, scheduler,
  boot receiver and notification intent retain their existing native class names
  and settings keys. There is no Flutter engine/channel dependency. Service and
  WorkManager both declare the matching specialUse/dataSync types. The wake lock
  is timed (10 minutes), renewed by the service and released on service destruction.
- `NativeClipboard` creates the platform ClipboardManager lazily on the main
  thread (required on API26), observes only while foregrounded, performs resume
  catch-up and retains the original 20-hash/60-second remote-loopback guard.
  Explicit history copying does not create another local-capture event. A failed
  history write can retry the same text without reverting newer clipboard state.
- Server teardown closes sockets before removing tracking entries and waits for
  the accept owner to finish before rebinding. Accepted/outbound sockets explicitly
  enable address reuse; repeated crossed connections and same-port restarts are
  covered, including a device-name-only settings change.

Instrumentation covers manager-to-manager direct sends without reciprocal
permissions, offline queued delivery, idempotent catch-up, connection edits,
foreground service receive after the Activity closes, shutdown and clipboard
baseline/resume/copy behavior. The later sections record completed real UI,
emulator Doze/reboot, signed phone upgrade and Mac/phone acceptance; emulator
results are not presented as exhaustive OEM behavior.

## Acceptance evidence and coverage limits

- Native APK/build/unit tests/Lint pass. The consolidated API26 log reports
  `OK (72 tests)`: 71 executed and passed, including real-server relay; one opt-in
  cold-start case was skipped in this run and verified separately below. Log:
  `/tmp/clipy-native-final-api26.txt`. No Flutter runtime library/assets are present
  in the native APK.
- API26 real relay fixture emitted explicit PASS only after group operations and
  1MiB encrypted v3 stream/ACK completed. Secure-storage corruption preserves old
  records; imported Dart journal fixtures are compatible.
- NLS real system tests passed collection/removal and loopback delivery/ACK. A
  separate prepare/cold/restore sequence proved a new process recovers already
  enabled notification collection without Activity or enable calls. API26's
  component-change broadcast delay is 10s, so only listener recovery has a 20s
  test allowance; storage/network assertions retain their original deadlines.
- A 1MiB/524288-line document originally exposed a low-heap TextView OOM. The
  replacement virtual document view caches at most three layouts and passed full selection, full-content copy callbacks, cross-block selection
  and bounded-memory assertions on API26.
- Real Flutter reference screenshots exposed and corrected app-bar/nav typography,
  chip sizing, CJK headings, medium dates, 12h time, sheet expansion and menu layout.
  The subsequent P0/P1 passes record the normal/large-font and appearance checks
  actually exercised; not every possible visual combination was sampled.
- Native libraries have verified 16KiB ELF/ZIP alignment. API37 reports
  `PAGE_SIZE=16384`; all eight relay tests executed and passed without skips,
  including real-server run `33ad7499`. Evidence:
  `/tmp/clipy-native-relay-16k-final.txt`. Third-party assets are packaged.
- Legacy migration fixtures cover history JSON, notification JSONL and file-history
  preferences, malformed-input rollback and preference-commit retry without duplicate
  imports. The completed phone before/after comparison is separate evidence.
- Android local acceptance and installation are complete. Coverage limitations
  (including emulator-only lifecycle scenarios and clock-sensitive invitations)
  remain explicit; public distribution and other platforms are separate work.

## Signed upgrade evidence and limits

The production release APK retains the original application ID and the phone's
release certificate, with versionCode 14285 above the previous Flutter 14284.
Artifact verification is recorded in `/tmp/clipy-native-production-verification.json`;
the later real-phone installation is verified separately in the final section.

On the API26 emulator, the signed Flutter 14284 application first displayed one
synthetic history entry. An in-place signed native 14285 upgrade retained that
entry in the UI, every history column/value, all existing preference entries and
the application UID. Evidence: `/tmp/clipy-signed-upgrade-emulator-proof.json`.
This proves the tested synthetic upgrade path only. The final phone cutover proof
separately covers its existing rows/files, identity, keys and permission state;
neither proof claims exhaustive OEM background behavior.

## P0-B real system entry and notification UI evidence

The isolated API26 preview and the real `.reference` Flutter application were
exercised through their normal MainActivity routes with the same synthetic
content. Evidence is under `/tmp/clipy-p0-b/` (`progress.json`, paired PNG/XML,
`share-driver.txt`, `driver-phases.txt`, and `cleanup.json`). This is a Chinese,
dark, normal-font-scale case, not blanket acceptance of every visual combination.

- Real `ACTION_SEND` text and `ACTION_SEND_MULTIPLE` with two content URIs entered
  the actual review screen. Device settings roundtrip retained the content and
  selected receiver. An opt-in UI driver held a real encrypted loopback receiver;
  manual UI sends produced one successful file and one real failed ACK. Manual
  retry transmitted only the failed file: metadata counts were one and two,
  respectively, and both received files matched byte-for-byte. Success closed the
  share route and left no staged files. This driver ran separately and passed;
  an assumption skip in an ordinary suite is not its execution evidence.
- Notification settings/history tabs, application search and collect/sync gating,
  system permission settings return, grouped history, long-press detail and body
  dragging were checked. The corrected detail starts at native 628/reference 629
  pixels and reaches native 111/reference 112 pixels at the 95% limit. Dragging
  the handle upward does not expand the sheet; dragging its body does.
- Real keyboard tests confirmed search fields move into view, incoming sharing
  hides a late keyboard request, and one Back from device settings returns to
  sharing. Keyboard-mode focus highlights induced by adb input disappear on touch
  and are not treated as layout defects.
- Corrections include filled compact app search, ListTile dimensions/alignment,
  count backgrounds, compact summary actions, button colors and spacing, modal
  scrim and draggable-sheet constraints. Shared system-navigation bar color
  (native gray versus reference black) and remaining font raster differences
  were referred to the shared UI pass. The subsequent P1 pass verified the API26
  black navigation bar and corrected selectable-text wrapping; complete pixel
  equivalence across every configuration is not claimed.
- Cleanup restored the preview's original four UI/filter preferences, removed
  only the two synthetic notification rows, and revoked only the temporary
  reference listener grant. The preview's pre-existing listener grant was kept;
  the production package was not touched by this UI exercise.

Additional platform evidence: launcher timer pin/start/pause/reset, retained
running state across update and natural expiry notification are recorded in
`/tmp/clipy-platform-timer*.xml`. Six isolated storage tests also passed on the
phone, including corrupt-database protection (`/tmp/clipy-native-phone-storage-final.txt`).
The installed Flutter 14284 data has a private pre-upgrade backup with per-file
SHA, SQLite integrity and repeated-inspection consistency checks; its redacted
proof is `/tmp/clipy-phone-pre-upgrade-backup-proof.json`. The private backup
location is deliberately not published here. These were pre-upgrade checks. The final section records the subsequent native
phone installation and continuity verification.

## Relay real Main UI evidence

The API37 preview and Flutter reference ran through their normal MainActivity
routes on the same emulator, with Chinese/dark/normal font settings. Artifacts
are `/tmp/clipy-relay-ui/` paired PNG/XML files. Networking used an isolated
loopback server and generated fictional SDK identities only. The internal endpoint
exception requires both a debuggable build and the exact preview package, accepts
only `ws://127.0.0.1:<valid-port>/relay/v1/ws`, and rejects credentials/query/fragment
or alternate hosts/paths; production remains WSS-only. Unit tests cover that gate.

- Native UI created a group, displayed a compact invitation QR, and observed a
  Python SDK guest join automatically. The screenshot's actual QR decoded with
  ZXing to the invitation consumed by that independent guest.
- Manual mode kept the guest pending. Its independently calculated verification
  code matched the UI; enabling management and approving in the UI admitted a
  manager. The native owner then left through its confirmation dialog.
- The native applicant pasted a new invitation and displayed a matching pending
  code. After leaving the page, approval by the fictional manager completed when
  the applicant reopened the group page, with ordinary-member permissions.
- The ordinary native member renamed itself. External group disbanding caused
  refresh to show only the unavailable-group recovery card. Confirmed local cleanup
  restored onboarding. A second UI-created fixture verified invitation cancellation
  and native disband confirmation; both test groups were closed normally.
- Camera permission denial displayed the original error icon/message. Back restored
  the join page; a second launch and grant produced a real camera preview with no
  stale error. A subsequent successful optical scan used the emulator's real
  virtual-scene camera: a fresh fictional invitation was placed on a room poster,
  the official per-instance JWT-protected camera controls framed it, and ZXing
  recognized the camera frames. The scanner closed itself, Main completed joining,
  and an independent Python SDK refresh confirmed exactly two members with the
  native applicant an ordinary member. Evidence: `native-optical-final-attempt.png`,
  matching XML and `optical-server-proof.json` in the artifact directory. No scanner
  callback or ActivityResult was injected, and no product decoding code changed.
  Both poster images were restored and the fixture group was disbanded normally.
  This is real emulator camera-pipeline evidence, not a physical-camera claim.
- Reference screenshots exposed and corrected stretched button widths, 18dp segment
  icons, whole-row switches, device-ID tooltip, creation hints, page visibility
  polling and field geometry. After removing Compose's extra label slot, group
  field/button vertical positions differed by approximately one pixel in the tested
  viewport. The measured 22dp horizontal text inset is shared with connection forms;
  later rebuilt captures and the P1 checks supplement this case; other visual
  combinations were not exhaustively sampled.

No personal enrollment or production package was used in this UI run. These
results remain distinct from the later phone identity/Keystore continuity checks
and user acceptance; not every membership operation was repeated on the phone.

## Emulator lifecycle and actual Doze evidence

`/tmp/clipy-native-lifecycle-proof.json` records receipt/ACK with the Activity
backgrounded, process termination with `kill -9` followed by START_STICKY recovery
under a new PID, and emulator reboot followed by receipt/ACK without opening an
Activity. Device identity remained unchanged; fixture preferences and rows were
restored. This is system-process-death recovery, not an assertion that a user
force-stopped Android package can bypass the platform's stopped state.

The first lifecycle run did not actually enter Doze because this emulator had
Doze disabled; that attempt is not counted as Doze acceptance. The separate
`/tmp/clipy-native-doze-proof.json` explicitly enabled deep idle, forced `IDLE`,
verified the process stayed alive, then exited idle and confirmed a fresh ACK.
Its `passed` and `restored` results are true, including restoration of the original
Doze-disabled configuration. It proves recovery after real emulator idle, not
unrestricted network delivery while idle, nor MIUI physical-device equivalence.

## P1-D real Main flows and final geometry checks

Evidence is in `/tmp/clipy-p1-d/progress.json` and the paired PNG/XML files in that
directory. These are normal product routes with fixed synthetic input, not the
standalone visual-fixture Activity.

- Logs: actual copy-all produced success feedback; cancelling clear retained the
  rows; confirming clear reached the same empty state in native and Flutter.
  The initial native page held 235 preview test logs; three shared synthetic log
  records were also captured for formatting comparison. No personal log content
  was published.
- Diagnostics: the native page advanced a synthetic error age from 19 to 23
  seconds and Flutter from 13 to 17 seconds without user refresh. Both reset to
  empty. The opt-in native UI driver passed separately, including the final
  corrected layout (`native-diagnostics-final-driver.txt`). Flutter's
  `SelectableText` reserves its 2dp cursor plus 1dp caret gap; the native selectable
  regions now reserve the same 3dp, restoring the reference's line wrapping.
- History: cancelling clear preserved the synthetic image/files; confirming it
  produced empty history on both apps. Image and two-file full-text previews were
  exercised. The corrected native 65% modal uses the full app viewport and scales
  images with their aspect ratio: the shared PNG's visible bounds are exactly
  `[79,453,641,734]` in both captures (`media-geometry-proof.json`). Dialog content
  starts within one physical pixel of the reference after the width correction.
- Settings: actual UI changes to Chinese with both dark and light appearance
  persisted across process restarts. The final light check verified a new PID,
  Chinese UI and the source light-background color (`settings-restart-proof.json`).
- Width and reduced motion: both apps use rail at 720dp and bottom navigation
  below that boundary. The final native destination step is 112px at density 1.75,
  exactly 64dp (`rail-spacing-final-proof.json`). With animation scales set to
  zero, sampled immediate Settings content equalled settled pixels on both apps
  (`motion0-proof.json`); this is a sampled transition check, not exhaustive
  frame analysis of every animation.
- Cleanup: the original preview history (zero rows) and logs (235 rows), including
  their sequence values, were restored exactly. The two appearance/language
  preferences, display size/density and all three animation settings were restored;
  the synthetic private PNG was removed. SQLite integrity passed. See
  `cleanup.json`. Neither the production package nor the phone was changed by P1.

The preview source label/version and live relative times naturally differ between
captures; those are not redesigned UI. The later handset section records the
completed installation and continuity checks; the wider multi-platform migration
is still separate from Android local acceptance.

## Running macOS app interoperability — bidirectional

The isolated native preview connected through its own UUID and uniquely named
fixture device to the already running macOS application, without rebuilding the
Mac app or changing group membership/automatic-sharing permissions.

- Native Main's explicit text-send UI reached the Mac clipboard exactly and a
  read-only lookup of the fixture hash found one durable history row. Native
  diagnostics showed an ACK, zero pending messages and the Mac still unauthorized
  for automatic sharing.
- Native Main's system file picker sent a uniquely named fictional binary. The
  running Mac saved it in its normal receipt directory; its SHA-256 matched the
  source, and the native UI reported delivery success.
- The Mac clipboard was privately saved with all original types before testing.
  Restoration occurred only while it still held the fixture marker, and a private
  comparison confirmed every type's bytes were restored. No original clipboard
  content is present in the redacted proof.
- After the user unlocked the host, a fresh all-type clipboard snapshot was made.
  The running Mac's actual send-text dialog was checked for the uniquely named
  preview destination before submission. Native Main's history displayed the
  exact marker. The Mac's actual file picker then sent the other fixture binary;
  Native Main's received-files page showed it, and its real Downloads/Clipy bytes
  had the same SHA-256 as the Mac source. These were explicit UI sends from the
  installed Mac application, not a protocol script impersonating either device.
- The post-unlock Mac clipboard already matched the fresh snapshot in every type,
  so no restoration/write was necessary. No lock, permission, group membership,
  signing or automatic-sharing configuration was changed; phone production
  data/application were untouched by this cross-platform test.

Redacted results: `/tmp/clipy-mac-native-5264889844/proof.json`. The surrounding
private working directory also contains a clipboard backup and must **not** be
published or uploaded as a whole. Only the redacted proof is distribution-safe.

## Final build and handset acceptance

- Source build `1.0.32+12285` now produces actual native Android `versionCode=14285`
  through the public build entry point. The current production candidate retains
  the original application ID/certificate and system-backup eligibility, declares
  every previously granted permission, has verified 16KiB ZIP alignment, and has
  no Flutter runtime or debug fixture Activity. See
  `/tmp/clipy-native-ready-production-proof.json`. This build has now replaced
  Flutter 14284 on the phone through an in-place signed upgrade.
- The consolidated API26 and API37 runs each report 77 tests: 74 execute and pass;
  cold-start, share UI driver and diagnostics UI driver are three opt-in skips,
  with their independent scenario evidence recorded above. Logs:
  `/tmp/clipy-native-candidate-all-api26.txt` and `...-api37.txt`.
- Follow-up clipboard/pagination instrumentation passes all three tests on each
  API after the final capture correction. Resume polling preserves original
  indentation/newlines and ignores non-text URI clips, matching the pinned Flutter
  embedding; foreground native-listener behavior remains distinct. Password-manager
  exclusions now use the original defaults when no override exists; an explicit
  empty/custom list is respected. JVM tests and Lint pass.
- Pagination now appends the next 50 rows, preserves loaded rows until explicit
  refresh, and resets the loaded range on search, matching `HistoryFeedController`.
  No content-length or history-count limit was reduced to make a test pass.
- Secure storage explicitly passes Flutter 10's OAEP/GCM options. The Java fallback
  alone would have initiated an unnecessary algorithm migration. The shipping-options
  fixture verifies identity ciphertext, algorithm/wrapped-key preferences and the
  OAEP certificate remain unchanged, including actual `RelaySecureStore.identity()`.
  All three secure-storage tests pass on the Mi 10's isolated preview. The original
  installed app's stored algorithm markers were separately checked against these options.
- The signed inspection tool has produced a private host backup of the existing
  app, verified ZIP/file hashes and SQLite integrity, and repeated read-only data
  comparisons. Keystore keys are not exported. Endpoint-cache and relay-configuration
  ciphertext may change during the **old app's** own background refresh; do not
  treat those two dynamic fields as an identity fingerprint. The standalone identity,
  stored algorithms/wrapped keys and Keystore identity must be checked separately.
- The low-memory large-document test verifies full selection, full content passed
  to the copy callback, failure feedback and bounded layout caching. It does not
  assert that the OS clipboard accepts a payload of that size; ordinary clipboard
  integration and UI actions are covered separately.
- Earlier handset foreground instrumentation timed out launching its Activity;
  that failed automated attempt is not reclassified as a pass. Subsequent physical
  installation, exact receive checks and the user's acceptance provide the final
  handset evidence below. Lock-screen/input-security restrictions were not disabled.

### Completed production phone cutover

The original `com.clipyclone.clipy_android` installation was upgraded in place
from 14284 to 14285 with the same certificate and UID 10418.
`/tmp/clipy-phone-cutover-verification.json` passes all recorded comparisons:
existing clipboard-history, notification and file-transfer rows; received-file
SHA values; stable identity/preferences; Keystore alias and certificate hashes;
permission grants, notification access, widget count, backup eligibility, battery
exemption and exact-alarm state. Two ordinary dynamic configuration/cache fields
were explicitly separated from stable identity rather than falsely reported as
unchanged. Private backup locations, keys and user content are not published here.

Mac-to-phone automatic verification found exactly one matching text row by hash
and a 2,816-byte file with the expected SHA-256
(`/tmp/clipy-phone-live-receive-proof.json`). The user confirmed that Android text
sending, file sending and sharing work. Phone-to-Mac/share final acceptance is
therefore user testing; the particular `PHONE_TO_MAC` automated marker was not
found and no automated reverse-marker success is claimed.

The user explicitly keeps manual system time. The handset's approximately
+41-second offset relative to the test server triggers the shared SDK's automatic
invitation timing rejection; the old Dart client applies the same rule. This is
a documented, accepted environment limitation, not a native regression, and no
further time-change request is part of acceptance.

Phone test/preview/probe APKs were uninstalled and the production application was
opened. Temporary test servers and the additional test emulator were stopped.
Android local acceptance and installation are complete; this does not publish a
new Release, complete iOS/Windows migration or authorize removing their Flutter
runtime/tooling dependencies.

### Final cleanup and current user setting

The installed production APK is verified against the signed artifact in
`/tmp/clipy-native-final-delivery-proof.json`. The temporary phone preview,
instrumentation test APK and signed inspection APK were removed; the production
app was opened afterward. Task-owned relay/extra-emulator processes and reverse
mappings were stopped. Private upgrade backups remain available locally.

Sync was enabled and its service running at the upgrade checkpoint. After the
user's manual feature testing, the persisted sync setting is disabled; this
current setting was retained. Do not report that a foreground sync service is
running while sync is disabled. The user explicitly chose to keep manual system
time. No automatic-time or input-security setting was changed.

## Closeout audit

The original-ID installation, data/key/permission continuity and primary Android
flows have been delivered. This does not turn the matrix's unverified coverage
limits into passing results. The remaining follow-up checks include physical
camera scanning, timer wheel/preset/permission/OEM variants, physical notification
mirroring/boot behavior, large-file/storage-permission paths, and additional
locale/theme/font-scale combinations. No new defect is asserted by listing an
unexecuted case. The complete-goal status must not be inferred solely from the
successful installation or the user's text/file/share acceptance.

Code remains uncommitted and unpublished. The working tree also contains separate
macOS changes; review and select the intended scope before any authorized commit
or release. iOS/Windows native migration and removing the shared Flutter tree are
separate unfinished platform phases, not Android installation cleanup.
