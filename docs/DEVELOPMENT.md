# Development and release guide

## Toolchain

- macOS build: macOS with **Xcode 26 or newer** selected by `xcode-select`, including
  the macOS 26 SDK. Command Line Tools alone/older SDKs are not sufficient for the
  newest ScreenCaptureKit calls. The deployment target remains macOS 13.
- Flutter: **3.41.7**, pinned in `.fvmrc` and read by CI (FVM is optional).
  The lockfile requires Dart 3.11+. Do not upgrade dependencies just to run checks.
- Android: JDK 17, Android SDK, NDK `27.0.12077973`. Gradle uses its checked-in wrapper.
- Repository checks: Bash, Git and Python 3; no third-party Python packages.

Use your own shell proxy configuration when required by your network. Public
scripts do not assume a `proxy` alias, personal IP address or developer SDK path.

## Quick start

From the repository root:

```bash
cd clipy_android
flutter pub get --enforce-lockfile
cd ..
bash scripts/check.sh all
```

`all` runs repository checks, Dart formatting verification, static analysis and
Flutter tests. It does not connect to peers, install packages on a device or start
the app. CI also builds a debug APK and the native macOS bundle.

```bash
bash scripts/check.sh repo      # shell syntax, metadata tests, hygiene
bash scripts/check.sh flutter   # format + analyze + tests (dependencies resolved)
bash scripts/check.sh macos     # compile, package and validate; no install/launch
```

Use `dart format lib test tool` from `clipy_android/` before submitting Dart changes.
The hygiene check covers the working tree only, not past commits or all possible
credential formats. Current Swift 6 concurrency/SDK warnings are not yet a
zero-warning baseline; Swift language mode is explicitly 5.

## macOS

```bash
./build_macos_app.sh
# Explicit local installation, after quitting the running app:
INSTALL_APP=1 LAUNCH_APP=1 ./build_macos_app.sh
```

Output: `clipy_macos/ClipyClone.app` and `.app.dSYM`. Compilation happens in a
temporary directory; a failed build leaves the previous build intact. Opt-in
installation keeps the previous installed bundle in a printed temporary backup
directory. No process is killed, and no TCC permissions are reset by the script.

| Environment variable | Default / purpose |
| --- | --- |
| `APP_VERSION`, `BUILD_NUMBER` | `pubspec.yaml` version (`X.Y.Z+N`) |
| `INSTALL_APP`, `LAUNCH_APP` | `0`; launch also requires installation |
| `GENERATE_DSYM` | `1`; set `0` to omit debug symbols |
| `SIGN_IDENTITY` | `-` (ad-hoc); explicit certificate identity otherwise |
| `BUNDLE_ID` | Existing `com.yourdomain.ClipyClone`; keep stable for TCC grants |
| `MACOS_ARCH` | `arm64`; `x86_64` is an optional cross-build, not device-tested in CI |

The icon is built from `Clipy/Resources/AppIcon.png`; permission metadata is in
`clipy_macos/Resources/Info.plist`. New `.swift` files under `Sources/` are collected
automatically. The release workflow currently creates **ad-hoc signed, non-notarized**
macOS artifacts; a Developer ID/notarization pipeline remains separate work.

## Android

```bash
cd clipy_android
flutter build apk --debug --no-pub
```

Normal release builds require a persistent keystore. Copy
`android/key.properties.example` to `android/key.properties` and fill it locally,
or supply `CLIPY_KEYSTORE_PATH`, `CLIPY_KEYSTORE_PASSWORD`, `CLIPY_KEY_ALIAS` and
`CLIPY_KEY_PASSWORD`. Relative `storeFile` paths are resolved from `android/`.
Never commit the resulting file or keystore. See the official
[Flutter signing instructions](https://docs.flutter.dev/deployment/android#sign-the-app).

```bash
# From repository root, after configuring release signing:
./build_android_apk.sh
# Local smoke-test ONLY, explicitly allowing a debug-signed release-mode build:
CLIPY_ALLOW_DEBUG_SIGNING=1 ./build_android_apk.sh
```

Output: `dist/ClipyClone-Android-{armeabi-v7a,arm64-v8a}-v<version>.apk`.
`SPLIT_PER_ABI=0` creates one APK; the default split packaging targets ARM32/ARM64.
Build numbers now come directly from Flutter metadata, with no device-specific
minimum hidden in Gradle. The current source version and build number are recorded
in `clipy_android/pubspec.yaml`; keep them aligned with the current-version text in
both root README files. To upgrade a newer local or CI installation, explicitly
supply a higher `BUILD_NUMBER`. Changing signing keys prevents in-place APK upgrades;
back up user data before any uninstall/reinstall.

## Manual regression checks

Use test data and test devices. Unit tests do not establish that permissions,
background execution, OEM power management, capture or recording work correctly.

- Clipboard: text/image/file history, dedup, search, app exclusions and restart.
- Sync: both directions; denied/authorized peers; reconnect; persistence before ACK;
  custom pairing secret; zero-byte and multi-chunk files; receiver hash mismatch.
- Android: cold launch, cached-engine UI attach, background/force-stop/boot behavior,
  notification grants/listener, timer start/pause/finish/stop.
- macOS: menu open/close, capture/recording permissions, all capture paths,
  OCR child, closed-window/cache memory release, notification routing.

The optional probe sends an **existing** file and causes a normal received-file
entry on the destination. It never creates/overwrites its input and has no default
peer address. Do not run it against a device without permission:

```bash
cd clipy_android
dart run tool/e2e_file_send.dart <host> <existing-test-file>
```

Set `CLIPY_PAIRING_SECRET` securely in the environment when needed and
`CLIPY_SYNC_PORT` for non-default ports. The default empty-secret compatibility
mode has the limitations described in [SECURITY.md](../SECURITY.md).

## Release checklist

1. Resolve the **blocking macshot license/provenance review** in
   [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md). Do not describe the whole
   macOS binary as MIT-only until the applicable terms are established.
2. Run CI and device checks; document any unsupported/experimental platforms.
   iOS currently has no build/device validation in CI and Android-only native hooks.
3. Review dependency changes, data migrations, privacy permissions and logs.
   Enable repository branch protection/required CI and GitHub private vulnerability
   reporting in repository settings as appropriate (not configured by source files).
4. Configure Actions secrets `CLIPY_KEYSTORE_BASE64`, `CLIPY_KEYSTORE_PASSWORD`,
   `CLIPY_KEY_ALIAS`, `CLIPY_KEY_PASSWORD` using a backed-up release keystore.
   Missing credentials fail the workflow; debug keys are never an implicit fallback.
5. Update `clipy_android/pubspec.yaml`, `README.md` and `README_ZH.md` in the same
   change. Version tags must use `vX.Y.Z`, match the source version and never
   overwrite an existing tag. README source-version text is separate from the
   Release badge, which only tracks published releases, not drafts. CI build
   numbers use the checked-in build number plus the workflow run number. Keep
   them monotonically increasing across releases and any workflow/build-number
   policy changes.
6. A version tag or manual Release workflow runs checks and creates a **draft**.
   Inspect APK signing/upgrade compatibility, the macOS signing/notarization status,
   `SHA256SUMS.txt`, symbols and notices before manually publishing.

This setup does not retroactively audit old releases, Git history or third-party
licenses, nor does a draft automatically resolve distribution obligations.
