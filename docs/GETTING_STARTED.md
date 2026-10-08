# Get started with Clipy

**English** · [简体中文](GETTING_STARTED_ZH.md) · [Back to the project](../README.md)

## Downloads

Open the [latest published release](https://github.com/JunWeiUp/Clipy/releases/latest) (currently [v1.0.29](https://github.com/JunWeiUp/Clipy/releases/tag/v1.0.29)) and choose the asset matching your device. The latest link follows new public releases and excludes drafts; the release notes give the exact version and build number.

| Device | Asset to download from the release page |
| --- | --- |
| Mac with Apple Silicon, macOS 13+ | `ClipyClone-macOS-v<version>.zip` |
| Android, arm64 | `ClipyClone-Android-arm64-v8a-v<version>.apk` |
| Windows 10/11 x64, starting with v1.0.23 | `ClipyClone-Windows-x64-v<version>.zip` |

The release uploads these three packages; GitHub displays each one's SHA-256 digest. It also generates source-code archives separately. Current local source is **v1.0.29**, build **10190**; CI adds the workflow run number. If replacing a release APK with a local build, use the same signing key and a build number higher than the installed package; do not uninstall without backing up app data.

The macOS ZIP contains an **arm64** application; it is not an Intel or universal build. The Android release APK targets arm64; the local build script can also produce an ARM32 APK. Older published releases may omit Windows. iOS has no published installer; CI builds its source without signing. For development builds, read [Development](DEVELOPMENT.md).

## Install and try clipboard history

1. **Mac:** unzip the download, move `ClipyClone.app` to Applications, and open it. Find Clipy in the menu bar; it does not show a Dock icon. Quit an older running copy before replacing it. **Android:** install the APK for your device architecture and follow the installer's app-specific permission prompts.
2. On the Mac, copy a harmless phrase such as `Hello from Clipy`. Open the menu-bar app, then press **⇧⌘F** to search for it. Keep LAN sync off while first exploring local history.
3. Grant permissions for the features you choose to use. macOS **Accessibility** is used for simulated paste; **Screen Recording** is used for capture; **Local Network**, where prompted by your OS, is used for sync. Android notification access is needed for notification mirroring, not a prerequisite for trying local Mac history.

### If macOS blocks the first launch

The project's current build workflow does not notarize the app. Verify the download source and follow [Apple's instructions for the exact alert](https://support.apple.com/en-us/102445). For an unverified-developer alert, Apple describes an app-specific **System Settings → Privacy & Security → Open Anyway** exception when you trust the app. Do not treat an alert about damage or malware as the same case, or disable system-wide protection to install Clipy.

## Sync version notes

Current source uses pairing-free protocol v3; versions through v1.0.25 use v2. Upgrade both endpoints to v3 builds together; old peers report a version mismatch. AES-GCM uses a built-in default key and ignores old pairing codes. See [Security](../SECURITY.md) for the boundaries.

The macOS package includes modified macshot code and is distributed under [GPLv3](../LICENSE.GPL-3.0). Clipy-authored code remains under [MIT](../LICENSE); see [provenance and source access](../THIRD_PARTY_NOTICES.md).

## Connect Mac and Android

1. Put both devices on a trusted local network and keep both apps open for the first test. Prefer the same app version on both ends.
2. Enable LAN sync on both devices and refresh the device list. No pairing code is needed. Send text or files directly from the device page.
3. Enable LAN sync. In each device's device list, enable clipboard sharing to the intended other device. These outgoing sharing switches are directional; configure both ends for two-way automatic sharing. Notification sharing is a separate option.
4. Copy non-sensitive test text on the Mac and check the Android history. To test the other direction, keep the Android app in the foreground, use its clipboard/import controls as needed, and check Mac history. Android background clipboard capture depends on OS restrictions and the permissions available on your device.

### Devices do not appear

Check that both apps have sync enabled, their listener ports match (default **5566**), and the devices can reach one another. A guest Wi-Fi network may isolate clients. VPN routes or a firewall may also block local traffic. Use the app's manual **IP:port** entry if discovery misses a reachable device. Different Wi-Fi bands alone do not establish whether the devices can communicate.

### Devices appear, but text does not arrive

Explicit sends do not require sharing switches. For automatic sync, check the **sending** device’s clipboard-sharing switch. Both endpoints must run protocol v3 builds. Then retry with both apps visible and non-sensitive sample text. A missing Android notification permission affects notification mirroring and should be investigated separately from clipboard sharing.

### How do I change language?

Open the application's settings and select English or Simplified Chinese. The language links in GitHub's README change the documentation language only.

## Feedback

[Report a problem](https://github.com/JunWeiUp/Clipy/issues/new?template=bug_report.yml) or [suggest a feature](https://github.com/JunWeiUp/Clipy/issues/new?template=feature_request.yml). Include the app version, OS version, sending/receiving devices, and steps you tried. Remove clipboard content, pairing secrets, notifications, account names, and local addresses from diagnostics. For security reports, use the process in [Security](../SECURITY.md).

If Clipy helps you, a [Star on GitHub](https://github.com/JunWeiUp/Clipy) makes the project easier for other people to discover.
