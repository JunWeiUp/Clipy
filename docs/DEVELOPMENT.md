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
the app. CI always runs repository checks. Pull requests
build and test only affected platforms; shared Flutter source or configuration
changes run Android, Windows and iOS checks. Main/master pushes, manual CI runs
and Release calls run the full matrix, including the debug APK, native macOS
bundle, Windows runner and unsigned iOS application.

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
macOS artifacts. Ad-hoc signing is also the explicit policy for the Mac CI job;
it does not import certificates or use signing secrets.

### macOS CI downloads

`.github/workflows/macos.yml` is both a reusable workflow and the standalone
**macOS Build** manual entry point. `ci.yml` calls it for main/master pushes,
pull requests that affect macOS, manual CI runs and Release checks. Run
**Actions → macOS Build → Run workflow** to build independently of Flutter,
Android checks and Android signing credentials. The manual entry point becomes
available once the workflow is on the repository's default branch.

CI runs repository checks in a separate job; standalone macOS runs check the
repository directly. The macOS job runs native
regression checks, builds with `SIGN_IDENTITY=-`, validates version metadata
and arm64 architecture, then checks
the signature both before packaging and after extracting the app ZIP. The app
is zipped with `ditto` before upload to preserve its executable permissions.
`INSTALL_APP=0` and `LAUNCH_APP=0` prevent installation or launch on the runner.

The run summary links to an artifact containing only the app ZIP. License
notices are inside the app bundle, and the summary links to the bilingual
[installation guide](MACOS_INSTALL.md). Sign in to GitHub to download it within
30 days. These builds target Apple Silicon / macOS 13+; they are not Intel or
universal binaries, and are not public GitHub Releases.

The app version comes from `clipy_android/pubspec.yaml`; the build number is the
source build number plus the caller's `GITHUB_RUN_NUMBER`, matching the Release
formula. Run numbers are scoped to each workflow, so build numbers across manual
Mac, CI and Release runs are not a global sequence; reruns keep the same build
number. Artifact names also include run ID and attempt to distinguish them.
Check the run summary or app's `Info.plist` when switching build channels and use a higher
`BUILD_NUMBER` for a local replacement of a newer installed build.

Version tags and the combined manual **Release** workflow publish a normal,
latest release after checks and all three platform builds succeed. It uploads
only the macOS ZIP, Android arm64 APK and Windows x64 ZIP. Standalone Mac CI
still produces a development artifact and does not publish a release or require
Developer ID signing.

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
The Release workflow uploads only the arm64 APK; the ARM32 build remains a local
output of the shared script.
Build numbers now come directly from Flutter metadata, with no device-specific
minimum hidden in Gradle. The current source version and build number are recorded
in `clipy_android/pubspec.yaml`; keep them aligned with the current-version text in
both root README files. To upgrade a newer local or CI installation, explicitly
supply a higher `BUILD_NUMBER`. Changing signing keys prevents in-place APK upgrades;
back up user data before any uninstall/reinstall.

## Windows and iOS

Windows uses the Flutter runner in `clipy_android/windows/`. On Windows 10/11
x64 with Visual Studio C++ tools, run `flutter pub get --enforce-lockfile` and
`flutter build windows --release --no-pub -t lib/main_windows.dart` from `clipy_android/`, then
`./scripts/package_windows.ps1 -Version <version>` from the repository root.
The script includes the Flutter bundle and MSVC runtime DLLs, verifies the
extracted ZIP, and writes `dist/ClipyClone-Windows-x64-v<version>.zip`.
CI builds the runner and launches an extracted ZIP, checking that the SQLite
history database is created under the user's roaming application data directory.
The Release workflow repeats this check on the versioned ZIP. Clipboard, tray
and bidirectional sync behavior still need a real Windows desktop check before
public release.

iOS uses the same Flutter code with Swift platform channels. CI builds with
`flutter build ios --release --no-codesign --no-pub` and compiles the simulator
runner with Xcode. It does not export an IPA or upload to TestFlight. On a Mac,
verify UI and storage in Simulator; local-network permissions, user paste and
foreground/background reconnect still need a signed physical-device check.

## Manual regression checks

### App icons

The approved master and reproducible platform exports are documented in
[the branding guide](../assets/branding/README.md). To update all launcher icons
and both README logos together, run on macOS:

```bash
swift scripts/export_app_icons.swift
python3 scripts/check_icons.py
```

Commit the resulting platform assets along with the source artwork. Normal app
builds consume the checked-in PNG/XML files and do not run image generation.
`scripts/check.sh repo` validates the icon resources on macOS and Linux. Review
the exported preview at small sizes, then verify installed launchers on target
devices; Android theme/mask choices and icon caches are launcher-dependent.

### Application behavior

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

Set `CLIPY_PAIRING_SECRET` to the receiver's pairing secret (the probe uses a
test-only default otherwise, which a real device will reject at handshake) and
`CLIPY_SYNC_PORT` for non-default ports. See [SECURITY.md](../SECURITY.md).

## Release checklist

1. Verify the macOS package contains `LICENSE`, `LICENSE.GPL-3.0` and
   `THIRD_PARTY_NOTICES.md`, and that the release notes link the exact-tag
   corresponding source. The combined macOS binary is GPLv3; see the
   [macshot provenance and modifications](../THIRD_PARTY_NOTICES.md).
2. Run CI and device checks before triggering Release; document any
   unsupported/experimental platforms. The workflow publishes automatically
   once its jobs pass.
   iOS has unsigned CI and Simulator coverage but no signed-device or public
   distribution validation. Windows needs a clean-machine ZIP and tray check.
3. Review dependency changes, data migrations, privacy permissions and logs.
   Enable repository branch protection/required CI and GitHub private vulnerability
   reporting in repository settings as appropriate (not configured by source files).
4. Configure Actions secrets `CLIPY_KEYSTORE_BASE64`, `CLIPY_KEYSTORE_PASSWORD`,
   `CLIPY_KEY_ALIAS`, `CLIPY_KEY_PASSWORD` using a backed-up release keystore.
   Missing credentials fail the workflow; debug keys are never an implicit fallback.
5. Update `clipy_android/pubspec.yaml`, `README.md` and `README_ZH.md` in the same
   change. Version tags must use `vX.Y.Z`, match the source version and never
   overwrite an existing tag. README source-version text is separate from the
   Release badge, which only tracks published releases. CI build
   numbers use the checked-in build number plus the workflow run number. Keep
   them monotonically increasing across releases and any workflow/build-number
   policy changes.
6. Before pushing a version tag or starting the manual Release workflow,
   inspect APK signing/upgrade compatibility, macOS signing/notarization and
   the bundled license notices. These triggers publish a **normal release**
   once checks pass. Verify the three uploaded package names and GitHub's
   per-asset SHA-256 digests after publication. The macOS app and Windows ZIP
   include `LICENSE` and `THIRD_PARTY_NOTICES.md`; Flutter's Android build
   includes generated dependency notices, while the repository's legal files
   remain available at the release tag.

This setup does not retroactively audit old releases, Git history or third-party
licenses; an automated public release does not resolve distribution obligations.
