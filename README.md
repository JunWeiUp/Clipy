# Clipy

A cross-platform clipboard management and synchronization tool for macOS and Android.

## Features

- **Clipboard History**: Automatically monitors and saves your clipboard history.
- **Cross-Platform Sync**: Synchronize clipboard data between macOS and Android devices in the same local network.
- **LAN File Transfer**: Send files directly between devices with hover menus on macOS and real-time progress tracking on Android.
- **Snippets**: Manage and quickly access frequently used text snippets or code fragments.
- **Secure Communication**: All data transmitted over the network is encrypted using AES-GCM 256-bit encryption.
- **Real-time Logs**: Integrated log viewer for monitoring sync status and debugging.
- **Customizable Device Names**: Set unique names for each device to easily identify them during synchronization.

## Architecture

### macOS App (Swift/AppKit)
- Native implementation for performance and system integration.
- Uses SwiftUI for the modern log window interface.
- Leverages Apple's `Network` framework for reliable mDNS discovery and TCP communication.

### Android App (Flutter/Dart)
- Cross-platform Flutter implementation for the mobile client.
- Uses `nsd` for mDNS discovery and native `Socket` for TCP communication.
- Supports both IPv4 and IPv6 for maximum compatibility.

## Synchronization Protocol

Clipy uses a custom TCP-based protocol for synchronization and file transfer:
- **Discovery**: Devices find each other using mDNS.
- **Protocol**: `[4-byte Big-Endian Length Prefix] + [Encrypted JSON Data]`
- **File Transfer**: Supports chunked transmission (512KB chunks) with metadata headers and real-time progress feedback.
- **Encryption**: AES-GCM 256-bit with a pre-shared key.
- **Loop Prevention**: Uses `lastSyncHash` to prevent synchronization loops between devices.

## Getting Started

### macOS
To build the macOS application:
1. Ensure you have Xcode installed.
2. Run the build script:
   ```bash
   ./build_app.sh
   ```
3. The application will be generated as `ClipyClone.app`.

### Android
To build the Android application:
1. Ensure you have Flutter SDK and Android SDK installed.
2. Navigate to the `clipy_android` directory:
   ```bash
   cd clipy_android
   ```
3. Run the Flutter build command:
   ```bash
   flutter build apk --debug
   ```

## Development

- **macOS Sources**: Located in the `Sources/` directory.
- **Android Sources**: Located in the `clipy_android/lib/` directory.
- **Task Log**: for a detailed history of the project development.

## License

Internal Project.
