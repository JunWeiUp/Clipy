# Clipy Flutter / Android

Clipboard history, LAN sync, file transfer and Android notification mirroring.
This is the mobile application, not a reusable pub.dev package.

From the repository root:

```bash
cd clipy_android
flutter pub get --enforce-lockfile
cd ..
bash scripts/check.sh flutter
cd clipy_android
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
