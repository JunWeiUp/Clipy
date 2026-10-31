# Clipy native Android migration

Android requires Android 8.0 (API 26) or newer.

Kotlin + Jetpack Compose implementation of the existing Android app. The final
contract is unchanged functionality, UI, interaction and upgrade data; this is
not a redesign. The original Flutter Android app remains the visual reference.
See [the parity checklist](../docs/NATIVE_MIGRATION_PARITY.md) for acceptance evidence and coverage limits.

The default application ID is `com.clipyclone.clipy_android.nativepreview` for
isolated development. The native APK has no Flutter engine, Dart runtime or
Flutter Gradle plugin. LAN sync, background service, notification collection and
mirroring, files, sharing and relay/device groups are integrated. Android local
acceptance and the original-ID, same-certificate phone upgrade to versionCode
14285 are complete. Existing data, identity, permissions and UID were retained.
The user confirmed text/file sending and sharing work; automatic Mac-to-phone
text/file checks also passed. This is a local installation, not a new public
Release. Public releases and `build_android_apk.sh` use the Flutter app again;
build this port with `build_android_native_apk.sh`. iOS/Windows migration and Flutter removal remain separate work.

## Build and verify

Requires JDK 17 and Android SDK platform 36. Set `ANDROID_HOME` to your SDK path
(or use an ignored `local.properties`). From the repository root:

```sh
./clipy_android_native/gradlew -p clipy_android_native :app:assembleDebug :app:testDebugUnitTest :app:lintDebug
./clipy_android_native/gradlew -p clipy_android_native :app:assembleDebugAndroidTest
```

Debug APK: `app/build/outputs/apk/debug/app-debug.apk` within this directory.
Tests use explicitly selected emulators and synthetic data. NLS system tests need
test listener access; relay live tests need an isolated local relay server and
`relayTestUrl`. See `notifications/TESTING.md` under the native source directory.
Do not run fixture seeding against a production application ID.

The reference UI uses the actual Flutter widgets in a separate `.reference` app:

```sh
cd clipy_flutter
ORG_GRADLE_PROJECT_nativeParityReference=true flutter build apk --debug --no-pub -t tool/native_ui_reference.dart
```

That build verifies its private storage path before writing fictional fixtures.
Its package is separate from both production and the native preview.

## Production build support

`-PnativeProduction=true` selects the original application ID and label. It reads
the existing ignored Android `key.properties` or the existing `CLIPY_KEYSTORE_*` /
`CLIPY_KEY_*` environment variables. A production release requires that signing
identity; there is no ad-hoc fallback. Commands build only and never install.

```sh
BUILD_NUMBER=<actual-version-code-greater-than-installed> ./clipy_android_native/gradlew -p clipy_android_native -PnativeProduction=true -PnativeAbi=arm64-v8a :app:assembleRelease
```

Version name and default build number still come from the shared pubspec as plain
text. Native `BUILD_NUMBER` is the actual Android versionCode; older Flutter
split APKs added ABI offsets, so compare the installed APK's real code before
upgrading. Release minification is currently disabled to preserve the JNA/reflection
ABI. The installed local build passed certificate, runtime and data/permission
continuity checks. Repeat the applicable checks for subsequent upgrade artifacts;
the build command itself does not perform installation or acceptance.

The optional [signed upgrade inspection tool](upgradeProbe/README.md) creates a
local checkpoint of the installed production app and records private-data hashes,
UID, permissions and Keystore alias hashes for before/after comparison. Its
separate APK uses the original signing identity and has no launcher; it never
replaces the application or exports hardware-backed keys.

## Structure and distribution

- `data/`: v6-compatible SQLite repositories and non-destructive legacy imports.
- `sync/`: v3 framing/crypto, sessions, discovery, reliable history and file streams.
- `notifications/`, `sharing/`, `relay/`: native platform workflows and relay SDK.
- `ui/`: the four original routes, settings, dialogs and full-text/document views.
- The original package names remain for NLS, timer, foreground service and workers.
  An activity alias preserves the old launcher/share component.

Material Icons retain the original glyphs and license. Body text uses the platform
sans-serif family, matching the real reference APK rather than bundling unused
Roboto assets. Directly ported SDK sources and native dependencies have packaged
notices under `app/src/main/assets/third_party/`.

## Local acceptance evidence and known limitation

- `/tmp/clipy-phone-cutover-verification.json`: original ID/certificate and UID
  10418 retained; existing rows/files, stable preferences, identity, Keystore
  aliases/certificates and permission/power/alarm state preserved. Normal dynamic
  configuration/cache changes are recorded separately.
- `/tmp/clipy-phone-live-receive-proof.json`: one exact matching text row and a
  2,816-byte file with matching SHA-256 received from the Mac. Phone sending and
  sharing were accepted by the user; the specific reverse-direction automated
  marker was not found and is not reported as an automatic pass.
- The user retains manual time. The existing shared SDK's automatic-invitation
  rule rejects the observed approximately +41-second handset/server clock skew,
  just as the old Dart client does. No clock change is required for this local
  acceptance; the invitation limitation remains documented.

Temporary phone test/preview/probe APKs were removed, the production app was
opened, and temporary test servers/additional emulator were stopped. Private
backup locations and user content are intentionally omitted.
