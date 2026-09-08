# Get started with Clipy

**English** · [简体中文](GETTING_STARTED_ZH.md) · [Back to the project](../README.md)

## Downloads

These links point to **v1.0.18, published September 8, 2026**, currently marked Latest. They are versioned downloads, not automatic pointers to future releases. See [all releases](https://github.com/JunWeiUp/Clipy/releases) for newer builds and their notes.

| Device | Download |
| --- | --- |
| Mac with Apple Silicon, macOS 13+ | [macOS ZIP](https://github.com/JunWeiUp/Clipy/releases/download/v1.0.18/ClipyClone-macOS-v1.0.18.zip) |
| Android, arm64 | [64-bit APK](https://github.com/JunWeiUp/Clipy/releases/download/v1.0.18/ClipyClone-Android-arm64-v8a-v1.0.18.apk) |
| Android, armeabi-v7a | [32-bit APK](https://github.com/JunWeiUp/Clipy/releases/download/v1.0.18/ClipyClone-Android-armeabi-v7a-v1.0.18.apk) |

The release also provides [SHA-256 checksums](https://github.com/JunWeiUp/Clipy/releases/download/v1.0.18/SHA256SUMS.txt) for the APK and ZIP files. Published packages use build **10078**; local v1.0.19 source defaults to **10080**. If replacing a release APK with a local build, use the same signing key and a higher build number; do not uninstall without backing up app data.

The macOS ZIP contains an **arm64** application; it is not an Intel or universal build. There is no published iOS installer in this release. The iOS source target is experimental. For development builds, read [Development](DEVELOPMENT.md).

## Install and try clipboard history

1. **Mac:** unzip the download, move `ClipyClone.app` to Applications, and open it. Find Clipy in the menu bar; it does not show a Dock icon. Quit an older running copy before replacing it. **Android:** install the APK for your device architecture and follow the installer's app-specific permission prompts.
2. On the Mac, copy a harmless phrase such as `Hello from Clipy`. Open the menu-bar app, then press **⇧⌘F** to search for it. Keep LAN sync off while first exploring local history.
3. Grant permissions for the features you choose to use. macOS **Accessibility** is used for simulated paste; **Screen Recording** is used for capture; **Local Network**, where prompted by your OS, is used for sync. Android notification access is needed for notification mirroring, not a prerequisite for trying local Mac history.

### If macOS blocks the first launch

The project's current build workflow does not notarize the app. Verify the download source and follow [Apple's instructions for the exact alert](https://support.apple.com/en-us/102445). For an unverified-developer alert, Apple describes an app-specific **System Settings → Privacy & Security → Open Anyway** exception when you trust the app. Do not treat an alert about damage or malware as the same case, or disable system-wide protection to install Clipy.

## Sync version notes

The published v1.0.18 and current `main` source provide pairing settings that the older v1.0.15 release did not:

| Build | Pairing behavior |
| --- | --- |
| Legacy v1.0.15 | Uses a public compatibility key; no private pairing-secret setting in its UI. It does not provide confidentiality against someone who knows that key. |
| Published v1.0.18 / current source | Exposes a private pairing-secret setting. Set the same strong, non-empty secret on both devices; an empty value falls back to compatibility mode. |

The intended environment is a trusted local network. If you still use v1.0.15, use only non-sensitive sample text; do not use that release to synchronize secrets. A private secret in v1.0.18 does not add authenticated device identity or remove all protocol limitations. Read [Security](../SECURITY.md) before enabling sync.

The existing [third-party license review](../THIRD_PARTY_NOTICES.md) remains open. Published release status does not mean that review has been completed.

## Connect Mac and Android

1. Put both devices on a trusted local network and keep both apps open for the first test. Prefer the same app version on both ends.
2. In v1.0.18, save the same strong, private **Pairing secret** in Settings on both devices **before** enabling LAN sync. v1.0.15 has no such setting; apply the limitations above. Avoid mixing private-secret mode with an older build that cannot use that secret.
3. Enable LAN sync. In each device's device list, enable clipboard sharing to the intended other device. These outgoing sharing switches are directional; configure both ends for two-way automatic sharing. Notification sharing is a separate option.
4. Copy non-sensitive test text on the Mac and check the Android history. To test the other direction, keep the Android app in the foreground, use its clipboard/import controls as needed, and check Mac history. Android background clipboard capture depends on OS restrictions and the permissions available on your device.

### Devices do not appear

Check that both apps have sync enabled, their listener ports match (default **5566**), and the devices can reach one another. A guest Wi-Fi network may isolate clients. VPN routes or a firewall may also block local traffic. Use the app's manual **IP:port** entry if discovery misses a reachable device. Different Wi-Fi bands alone do not establish whether the devices can communicate.

### Devices appear, but text does not arrive

Check the outgoing clipboard-sharing switch on the **sending** device. In v1.0.18, check that pairing secrets match. Then retry with both apps visible and non-sensitive sample text. A missing Android notification permission affects notification mirroring and should be investigated separately from clipboard sharing.

### How do I change language?

Open the application's settings and select English or Simplified Chinese. The language links in GitHub's README change the documentation language only.

## Feedback

[Report a problem](https://github.com/JunWeiUp/Clipy/issues/new?template=bug_report.yml) or [suggest a feature](https://github.com/JunWeiUp/Clipy/issues/new?template=feature_request.yml). Include the app version, OS version, sending/receiving devices, and steps you tried. Remove clipboard content, pairing secrets, notifications, account names, and local addresses from diagnostics. For security reports, use the process in [Security](../SECURITY.md).

If Clipy helps you, a [Star on GitHub](https://github.com/JunWeiUp/Clipy) makes the project easier for other people to discover.
