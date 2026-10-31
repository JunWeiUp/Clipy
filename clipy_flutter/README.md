# Clipy Flutter

Android requires Android 8.0 (API 26) or newer.

Clipboard history, LAN sync, file transfer and Android notification mirroring.
This is the shared Android, Windows and iOS application. It is not a reusable pub.dev package.

The directory and Dart package were renamed from `clipy_android` to
`clipy_flutter`. Installed application IDs, platform channels and stored data
keys retain their original names for upgrade compatibility.

From the repository root:

```bash
cd clipy_flutter
flutter pub get --enforce-lockfile
cd ..
bash scripts/check.sh flutter
cd clipy_flutter
flutter build apk --debug --no-pub
```

Use Flutter 3.41.7 and JDK 17. `lib/main.dart` is intentionally small;
`lib/app/` owns startup/headless integration and `lib/features/` owns pages.
Repositories live in `lib/database/`; wire code is in `lib/sync/`.
Android platform channels and services are in `android/app/src/main/kotlin/`.

The `ios/` target is experimental: it is not validated in CI and does not provide
the Android-native notification/background-service integration.

See [Development and signing](../docs/DEVELOPMENT.md),
[Architecture](../docs/ARCHITECTURE.md), [Protocol](../docs/PROTOCOL.md),
[Contributing](../CONTRIBUTING.md) and [Security](../SECURITY.md).
