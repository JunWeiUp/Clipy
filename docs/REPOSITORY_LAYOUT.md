# Repository layout and dependency policy

## Clients

| Directory | Role | Status |
| --- | --- | --- |
| `clipy_flutter/` | Shared Flutter application: Android, Windows, iOS | Public Android/Windows builds; iOS target retained |
| `clipy_macos/` | Swift/AppKit macOS app, resources and regression tests | Public macOS build |
| `clipy_android_native/` | Kotlin/Compose Android alternative | Kept, not released |
| `clipy_nsh/` | NSH experiment and its host bridges | Paused; do not resume or delete as routine cleanup |

`clipy_flutter/pubspec.yaml` remains the shared app-version source. The directory
and Dart package changed from `clipy_android`; Android application IDs, Kotlin
namespaces, platform-channel names, database/preference keys and secure-storage
aliases retain their original values so installed data and updates stay compatible.
Do not replace these identifiers when renaming a source directory.

Both Android app implementations require Android 8.0 (API 26) or newer.
The separate upgrade-inspection tool remains API 30 because it uses SQLite
`VACUUM INTO`; it is not a distributed application.

## Shared support

| Location | Responsibility |
| --- | --- |
| Root `build_*.sh` | Public build entrypoints |
| `scripts/` | Shared build configuration, checks, icon generation and test runners |
| `packages/relay-swift/` | Thin static-library product for swiftc, SDK manifest and lockfile |
| `.github/` | CI, releases and contribution templates |
| `docs/` | Architecture, design standards, development, protocol and feature guides |
| `docs/design/` | Retained design references, including `clipy.pen` |
| `assets/branding/` | Branding inputs and asset generation notes |
| `clipy_macos/Resources/` | macOS-specific icon and app metadata |
| `res/screenshots/` | Sanitized README screenshots |

The ongoing local `design/` and `macos-ui-overview.html` work is kept in place.
This cleanup does not relocate or remove another task's uncommitted artifacts.

## Dependencies and removed implementations

Flutter uses the official Common Relay `v0.1.3` Git dependency in `sdk/dart`.
macOS uses the same release through SwiftPM; both lockfiles pin commit
`00a9de180ce0986231a5ccc75b773164f64b5133`. See
[Common Relay integration](COMMON-RELAY-SDK.md) for native Android’s pinned JitPack dependency and upgrade checks. SDK caches belong to package managers, not this
repository's source tree. Keep required dependency licenses in distributed apps.

The retired Python `relay/` server and its obsolete smoke tests were removed.
The standalone `Clipy/` icon directory was folded into macOS resources.
Common Relay Dart/Swift snapshots formerly under `vendor/common-relay/` were
replaced by package dependencies. Their previous implementations remain in Git
history; deployment instructions now point to the maintained upstream server.

## Generated and local files

`dist/`, client `build/` directories, `.dart_tool/`, `.gradle/` and SwiftPM
`.build/` are reproducible outputs. Use `python3 scripts/clean_generated.py`
to preview cleanup, and `--apply` to remove recognized ignored outputs.
Local signing files, user data, installed apps and NSH experiment evidence are
not routine source-cleanup targets. Run `bash scripts/check.sh repo` plus the
relevant client checks after changing paths or dependency manifests.
