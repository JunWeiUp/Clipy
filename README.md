<div align="center">

<img src="Logo.png" alt="Clipy" width="160" height="160" />

# Clipy

**A native macOS menu-bar clipboard manager & screenshot tool, with encrypted LAN sync to your phone.**

Clipboard history · Snippets & hotkeys · Screenshot annotation & on-device OCR · Global search ·
Phone-notification mirror · AES-GCM encrypted sync & file transfer

[English](README.md) | [中文](README_ZH.md)

[![Release](https://img.shields.io/github/v/release/JunWeiUp/Clipy?include_prereleases&label=Release&logo=github&color=2ea44f)](https://github.com/JunWeiUp/Clipy/releases)
[![CI](https://img.shields.io/github/actions/workflow/status/JunWeiUp/Clipy/ci.yml?branch=master&label=CI&logo=githubactions&logoColor=white)](https://github.com/JunWeiUp/Clipy/actions/workflows/ci.yml)
[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B%20·%20Android-blue?logo=apple)](#-download)
[![Language](https://img.shields.io/badge/built%20with-Swift%20·%20Flutter-orange?logo=swift&logoColor=white)](#-architecture)
[![License review](https://img.shields.io/badge/license-review_required-orange)](THIRD_PARTY_NOTICES.md)
[![Stars](https://img.shields.io/github/stars/JunWeiUp/Clipy?style=social&logo=star)](https://github.com/JunWeiUp/Clipy/stargazers)

</div>

[Development](docs/DEVELOPMENT.md) · [Architecture](docs/ARCHITECTURE.md) · [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md)

> Release readiness: the macshot-derived screenshot module needs a [third-party license review](THIRD_PARTY_NOTICES.md) before new combined binaries are published. The repository's MIT text is not a complete licensing statement for that module.

---

## ✨ Why Clipy

Clipy lives in your menu bar and quietly supercharges your clipboard. Beyond saving everything you copy, it bundles a **full screenshot & annotation tool with on-device OCR**, a **global search across your history**, and **encrypted sync** that mirrors your Android phone's clipboard, files, and notifications straight to your Mac — no cloud, no account, everything stays on your local network.

- 🔒 **Local-first** — sync payloads use **AES-GCM 256-bit** on trusted networks; configure a private pairing secret. History media can be encrypted at rest with keys in the macOS Keychain. See [security limitations](SECURITY.md).
- ⚡ **Native & lightweight** — pure Swift/AppKit on macOS (stays out of your Dock), Flutter on mobile.
- 🌍 **Bilingual** — switch between 中文 and English at any time.

## 🖼️ Screenshots

<p align="center">
  <img src="res/search.png" width="560" alt="Global search with regex and type / source-app / date filters" />
</p>

<p align="center"><sub>Global search (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>F</kbd>) — regex, type / source-app / date filters, ranked results.</sub></p>

> Screenshots for the **screenshot & annotation tool** and **notification mirror** coming soon.

## 🚀 Features

### 📋 Clipboard history
- Captures **text, RTF, HTML, PDF, images, and files** automatically.
- **SHA-256 dedup** — re-copying an item moves it back to the top instead of duplicating.
- **File-aware** — shows the source file path and can reveal it in Finder.
- **Exclude apps** by bundle id (password managers, Keychain, etc.).
- Configurable history limit and lazy-loaded menu for a tiny memory footprint.
- Optional **at-rest encryption** of history media (keys in macOS Keychain).

### ✂️ Snippets (macOS)
- Organize reusable text/code in **folders**, drag-to-reorder.
- **Global hotkeys** per snippet/folder with a built-in shortcut recorder.
- **XML import/export** of your snippet library.

### 📸 Screenshot & annotation (macOS)
- Capture modes: **region / window / fullscreen / scrolling long-screenshot / screen recording (MP4 + GIF)**.
- **18-tool annotation engine** (ported from [macshot](https://github.com/sw33tLie/macshot)) on a single unified overlay: pencil (pressure + smoothing), line, **6 arrow styles** (curved/dashed/sketchy), rectangle, filled rectangle, ellipse, **marker (multiply blend)**, rich text (bold/italic/outline/background), auto-incrementing **number**, emoji/image **stamp**, **pixelate/blur/solid/erase censor**, **loupe magnifier**, **pixel ruler**, **color sampler**, **spotlight highlight**.
- Per-tool **secondary options bar** + glass primary toolbar + color/emoji/font/effects popovers.
- **Beautify** gradient wrapping + **image effects** (brightness/contrast/saturation/sharpness).
- **Scrolling capture** with live side preview (Vision-based frame-stitch).
- **Recording** with system-audio + microphone, webcam overlay, mouse-click highlight, keystroke display.
- **On-device OCR** + **QR** via Apple Vision; **auto-redact** PII; **Apple Translation** overlay.
- **Pin to screen** (zoom/opacity/rotate/edit), **floating thumbnail** feedback, **standalone editor** window (crop/flip/zoom), save-as, copy.
- Configurable save directory, single-key tool shortcuts, and a global hotkey.
- Fully localized (English + Simplified Chinese).

### 🔍 Global search (macOS)
- Summon with <kbd>⇧</kbd><kbd>⌘</kbd><kbd>F</kbd> from anywhere.
- **Regex** support, plus filters by **type, source app, and date**.
- Ranked results, multi-select, copy/paste, and pin straight from results.

### 🔄 Encrypted LAN sync
- **AES-GCM 256-bit** encrypted transport between macOS and Android.
- Devices discover each other via **/24 subnet scan** and **manual IP:port** (works across 2.4G/5G subnets) — no cloud, no account.
- Reliable **clipboard history** delivery with ack + offline queue.
- Resilient: a bounded **offline-peer queue** re-delivers to devices that briefly drop off Wi-Fi.
- **Loop prevention** via content hashes, so copies never bounce between devices forever.

### 🔔 Phone-notification mirror (Android → macOS)
- See your Android phone's notifications right on your Mac.
- **Two-way** dismiss and clear-all; per-app **allow-list** filter.

### ⌨️ Global hotkeys & 🌍 i18n
- Hotkeys for search, screenshots, and every snippet.
- Chinese / English UI; native macOS and Flutter Android. The iOS target is experimental and not built or device-tested in CI; Android-native features are not available there by default.

<details>
<summary><b>🔐 A note on security</b></summary>

Use sync only on trusted networks and configure a strong private pairing secret. An empty secret uses a public compatibility key and does **not** protect traffic from someone who knows the source. The authorized-devices list is not cryptographic identity verification; one-shot text/file transfers have different authorization rules. See [SECURITY.md](SECURITY.md) for the full limitations.
</details>

## ⬇️ Download

Grab the latest build from the [**Releases**](https://github.com/JunWeiUp/Clipy/releases) page:

| Platform | Artifact |
| --- | --- |
| macOS 13+ (Apple Silicon) | `ClipyClone-macOS-v<version>.zip` |
| Android (64-bit) | `ClipyClone-Android-arm64-v8a-v<version>.apk` |
| Android (32-bit) | `ClipyClone-Android-armeabi-v7a-v<version>.apk` |
| iOS (experimental) | Source target only; not validated in CI |

> On first launch, grant **Accessibility** (paste simulation), **Screen Recording** (screenshots), and **Local Network** (sync) permissions in System Settings → Privacy & Security.

## 🛠️ Build from source

### macOS (Swift / AppKit)
Requirements: **Xcode 26+** with the macOS 26 SDK. The application deployment target is macOS 13.

```bash
./build_macos_app.sh
```

Generates `clipy_macos/ClipyClone.app` and debug symbols without installing or launching. After quitting the running app, opt in with `INSTALL_APP=1 LAUNCH_APP=1 ./build_macos_app.sh`. See [build and signing options](docs/DEVELOPMENT.md).

### Android / iOS (Flutter)
Requirements: Flutter **3.41.7** (see `.fvmrc`), JDK 17 and the Android SDK.

```bash
cd clipy_android
flutter pub get --enforce-lockfile
flutter build apk --debug      # Android
# iOS is experimental and not validated by this project's CI.
```

Release builds produce split APKs for `armeabi-v7a` and `arm64-v8a` and require explicit signing configuration. Run `bash scripts/check.sh all` from the root for local quality checks.

## 🏗️ Architecture

**macOS app** — Swift + AppKit, native menu-bar app (`LSUIElement`, no Dock icon):
- `MenuController` — status-bar menu: history, snippets, devices, and actions.
- `ClipboardManager` — pasteboard polling, history persistence, dedup, sync dispatch.
- `SnippetManager` — folders, snippets, hotkeys, import/export.
- `SyncManager` — subnet/manual discovery, length-prefixed TCP sync (protocol v2), AES-GCM encryption, reliable history + notification delivery.
- `Sources/Screenshot/` — the full screenshot/recording engine (ported from macshot): unified `OverlayView`, 18-tool annotation engine, scroll capture, recording, beautify/effects, OCR, pin, floating thumbnail, editor window. Driven by `ScreenshotSessionCoordinator`.
- `SearchWindow` — global search with filters and ranking.
- `NotificationManager` — phone-notification mirror.
- `PreferencesManager`, `SettingsWindow`, `SnippetEditorWindow`, `LogWindow` — config & editing surfaces.

**Android/iOS app** — Flutter/Dart:
- `lib/main.dart` — default entrypoint; `lib/app/` owns bootstrap and the headless bridge.
- `lib/features/` — device, history, settings, log and transfer pages.
- `lib/clipboard_manager.dart` — clipboard monitoring, history, sync coordination.
- `lib/sync_manager.dart` — subnet/manual discovery, TCP sync v2, encryption, history + notification delivery.
- `lib/notification_manager.dart` — `NotificationListenerService` integration.

## 🔁 Sync protocol

Clipy uses a LAN-first protocol v2 for clipboard history and notifications:

- **Discovery** — `/24` TCP port scan + manual `IP:port` peers (cross-subnet / dual-band).
- **Transport** — raw TCP with a 4-byte big-endian length prefix per JSON envelope (`v: 2`, max 2 MB/frame).
- **Messages** — `history`, `history.fetch`, `notif.post` / `dismiss` / `clear` / `ack`, `hello` / `welcome`, `ping` / `pong`, `ack`.
- **Encryption** — AES-GCM 256-bit on payloads (HKDF when a pairing secret is set).
- **Authorization** — outbound clipboard/notification push only to peers in each device's authorized list.
- **Reliability** — history frames require `ack` after persist; bounded offline queue + endpoint cache for reconnect.
- **Loop prevention** — content hashes prevent rebroadcast loops.

Full wire notes, headless Android channel rules, and code map: [`docs/PROTOCOL.md`](docs/PROTOCOL.md).

## 📁 Project structure

```
clipy_macos/Sources/      # macOS Swift/AppKit source
clipy_android/lib/        # Android & iOS Flutter/Dart source
build_macos_app.sh        # macOS app bundle build script
build_android_apk.sh      # Android split-APK build script
.github/workflows/        # CI + reviewed release drafts
res/                      # README assets
assets/                   # Logo & app icons
```

## 🤝 Contributing

Issues and pull requests are welcome in English or Chinese. See [CONTRIBUTING.md](CONTRIBUTING.md) and the [architecture map](docs/ARCHITECTURE.md). To contribute code:

1. Fork the repo and create a feature branch.
2. Run `bash scripts/check.sh all` and build the affected native platform.
3. Open a pull request describing your change.

## 📦 Releasing

After configuring release signing, version tags run CI and create a **draft** for maintainer review:

```bash
git tag v1.1.0
git push origin v1.1.0
```

The `Release` workflow can also be triggered manually with a version like `1.1.0`. Complete the [release checklist](docs/DEVELOPMENT.md#release-checklist), including licensing and signing review, before publishing the draft.

## 📄 License

The repository currently contains an [MIT License](LICENSE), but the macshot-derived screenshot module needs a separate license/provenance review. Do not assume the combined application is MIT-only. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## ⭐ Star History

[![Star History Chart](https://api.star-history.com/svg?repos=JunWeiUp/Clipy&type=Date)](https://star-history.com/#JunWeiUp/Clipy&Date)

---

<div align="center">

If Clipy saves you time, consider giving it a ⭐ — it really helps others discover the project!

</div>
