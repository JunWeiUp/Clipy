# Clipy

[中文](README_ZH.md) | English

Clipy is a cross-platform clipboard manager for macOS and Android. It keeps clipboard history, organizes reusable snippets, transfers files over the local network, and synchronizes data between nearby devices.

## Highlights

- **Clipboard history**: Automatically monitors, deduplicates, and stores clipboard content.
- **Snippets**: Organize frequently used text or code snippets in folders and paste them quickly.
- **LAN sync**: Synchronize clipboard history and snippets between macOS and Android devices on the same local network.
- **LAN file transfer**: Send files directly between devices with macOS hover actions and Android progress tracking.
- **Secure transport**: Encrypts network payloads with AES-GCM 256-bit encryption and a pre-shared key.
- **Real-time logs**: Built-in log windows help inspect sync, transfer, and debugging events.
- **Custom device names**: Give each device a clear name for easier discovery.
- **Chinese and English UI**: Switch the app language from preferences on both macOS and Android.

## Screenshots

### macOS Menu Bar

![macOS Menu Bar](res/menubar.png)

### Snippet Editor

![Snippet Editor](res/fragment1.png)

## Architecture

### macOS App

- Built with Swift and AppKit as a native menu bar app.
- `MenuController` renders the status bar menu and handles history, snippets, devices, and actions.
- `ClipboardManager` polls the system pasteboard, persists history, removes duplicates, and dispatches sync events.
- `SnippetManager` manages folders, snippets, shortcuts, imports, exports, and sync updates.
- `SyncManager` handles Bonjour discovery, HTTP sync endpoints, AES-GCM encryption, hashing, and deduplication.
- `SettingsWindow`, `SnippetEditorWindow`, and `LogWindow` provide the main configuration and editing surfaces.

### Android App

- Built with Flutter and Dart.
- `lib/main.dart` contains the tab-based UI for history, snippets, preferences, logs, and transfer actions.
- `lib/clipboard_manager.dart` monitors clipboard changes, stores history, and coordinates sync events.
- `lib/sync_manager.dart` handles service registration, discovery, HTTP sync, encryption, file transfer, and deduplication.
- `lib/app_localizations.dart` provides the Chinese and English text resources.

## Sync Protocol

Clipy uses a LAN-first sync protocol for clipboard, snippet, and file data:

- **Discovery**: Devices discover each other through Bonjour/mDNS.
- **Transport**: Sync data is exchanged through local HTTP endpoints.
- **Payloads**: Clipboard and snippet messages are JSON payloads encrypted before transmission.
- **File transfer**: Files are sent in 512 KB chunks with metadata and real-time progress updates.
- **Encryption**: AES-GCM 256-bit with a shared key configured on each device.
- **Loop prevention**: Content hashes such as `lastSyncHash` prevent rebroadcast loops.

## Build

### macOS

Requirements: Xcode command line tools.

```bash
./build_app.sh
```

The generated app bundle is `ClipyClone.app`.

### Android

Requirements: Flutter SDK and Android SDK.

```bash
cd clipy_android
flutter pub get
flutter build apk --debug
```

For release builds, the GitHub workflow builds split APKs for `armeabi-v7a` and `arm64-v8a`.

## Project Structure

- `Sources/`: macOS Swift/AppKit source code.
- `clipy_android/lib/`: Android Flutter/Dart source code.
- `.github/workflows/release.yml`: GitHub Release automation.
- `build_app.sh`: macOS app bundle build script.
- `res/`: README assets.

## GitHub Release

Release builds are published automatically when pushing a version tag:

```bash
git tag v1.0.0
git push origin v1.0.0
```

The `Release` workflow can also be run manually from GitHub Actions with a version such as `1.0.0`.

Published artifacts:

- `ClipyClone-macOS-v<version>.zip`
- `ClipyClone-Android-armeabi-v7a-v<version>.apk`
- `ClipyClone-Android-arm64-v8a-v<version>.apk`

## License

Internal project.
