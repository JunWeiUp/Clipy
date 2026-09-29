# Clipy macOS

Native Swift/AppKit menu-bar app. The main macOS target is not the Flutter UI.

From the repository root, with Xcode 26+ and the macOS 26 SDK selected:

```bash
./build_macos_app.sh
```

From this directory, use `../build_macos_app.sh` (there is no local wrapper).
The output is `ClipyClone.app` and its `.dSYM`; the default build does **not**
install, launch, terminate apps or reset permissions. The deployment target is
macOS 13; newer capture/translation APIs are availability-guarded.

`Sources/` is organized by feature. `Resources/Info.plist` is the reviewed bundle
metadata template. See [Architecture](../docs/ARCHITECTURE.md) and
[Development](../docs/DEVELOPMENT.md) for module boundaries, build options,
signing and device verification.

The distributed macOS application includes the screenshot port under
[GNU GPLv3](../LICENSE.GPL-3.0); see [provenance and source access](../THIRD_PARTY_NOTICES.md).
