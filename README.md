# Clipy

[中文](README_ZH.md) | English

Clipy is a cross-platform clipboard manager for macOS and Android. It keeps clipboard history, organizes reusable snippets, transfers files over the local network, and synchronizes data between nearby devices.

## Highlights

- **Clipboard history**: Automatically monitors, deduplicates, and stores clipboard content.
- **Snippets** (macOS): Organize frequently used text or code snippets in folders and paste them quickly.
- **LAN sync**: Synchronize clipboard history between macOS and Android devices on the same local network.
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
- `SnippetManager` manages folders, snippets, shortcuts, imports, and exports (local only).
- `SyncManager` handles Bonjour discovery, length-prefixed TCP sync, AES-GCM encryption, hashing, and deduplication.
- `SettingsWindow`, `SnippetEditorWindow`, and `LogWindow` provide the main configuration and editing surfaces.

### Android App

- Built with Flutter and Dart.
- `lib/main.dart` contains the tab-based UI for history, collector, preferences, logs, and transfer actions.
- `lib/clipboard_manager.dart` monitors clipboard changes, stores history, and coordinates sync events.
- `lib/sync_manager.dart` handles service registration, discovery, TCP sync, encryption, file transfer, and deduplication.
- `lib/app_localizations.dart` provides the Chinese and English text resources.

## Sync Protocol

Clipy uses a LAN-first sync protocol for clipboard and file data:

- **Discovery**: Devices discover each other through Bonjour/mDNS (`_clipy-sync._tcp`).
- **Transport**: Raw TCP with a 4-byte big-endian length prefix per JSON message (max 2 MB per frame).
- **Payloads**: Clipboard and file messages are JSON payloads encrypted before transmission.
- **File transfer**: Files are sent in 128 KB chunks over a single ordered connection with metadata and real-time progress updates.
- **Compression**: Text-like file chunks are gzip-compressed when beneficial (same rules on both platforms).
- **Encryption**: AES-GCM 256-bit.
- **Authorization**: Inbound messages are accepted only from peers checked in each device's authorized list.
- **Loop prevention**: Content hashes such as `lastSyncHash` prevent rebroadcast loops.

## Build

### macOS

Requirements: Xcode command line tools.

```bash
./build_macos_app.sh
```

The script lives at the repository root, generates `clipy_macos/ClipyClone.app`, and installs it to `/Applications`.

### Android

Requirements: Flutter SDK and Android SDK.

```bash
cd clipy_android
flutter pub get
flutter build apk --debug
```

For release builds, the GitHub workflow builds split APKs for `armeabi-v7a` and `arm64-v8a`.

## Project Structure

- `clipy_macos/Sources/`: macOS Swift/AppKit source code.
- `build_macos_app.sh`: macOS app bundle build script.
- `clipy_android/lib/`: Android Flutter/Dart source code.
- `.github/workflows/release.yml`: GitHub Release automation.
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
