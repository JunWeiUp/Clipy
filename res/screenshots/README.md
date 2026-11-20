# Product screenshots

English and Chinese screenshots of the current source build use fictional example content. Mac images are native snapshots rendered by the macOS core test executable without reading the user's clipboard history, snippets or devices.

The README begins with the cross-device concept artwork in `../readme/connected-hero.webp`. Its source and built-in imagegen prompt are documented in [../readme/PROMPTS.md](../readme/PROMPTS.md).

README gallery (both languages, compact WebP delivery copies):

| Asset | Source fixture | Shown at |
| --- | --- | --- |
| `macos-panel-{en,zh}.webp` | panel `english-history` / `light-history` | 300 px |
| `macos-{history,snippets,devices,notifications,tools,tools-keepawake}-{en,zh}.webp` | window `hub-*-light` | 400 px |
| `macos-capture-{en,zh}.webp` | editor `capture-selected` | 400 px |
| `macos-ocr-{en,zh}.webp` | capture results `ocr-light` | 400 px |
| `android-{history,devices,settings-dark}-en.webp` | emulator PNGs below (used in both READMEs) | 200 px |

Each `*-en` / `*-zh` pair renders the same fictional fixture with English or Chinese interface and content. Render with `bash scripts/test_macos_core.sh` and these variables:

- `CLIPY_PANEL_SNAPSHOT_DIR` (produces both languages)
- `CLIPY_WINDOW_SNAPSHOT_DIR`, `CLIPY_EDITOR_SNAPSHOT_DIR`, `CLIPY_CAPTURE_RESULTS_SNAPSHOT_DIR` — add `CLIPY_SNAPSHOT_LANGUAGE=en` for the English set (default Chinese).

Export each at most 1000 px on the long edge (panel 700 px, Android 900 px) and encode with `cwebp -q 80`, keeping each file under ~40 KB. Keep both README files in sync when replacing images. Screenshots describe the source build and may include changes not yet in a published release.

## Android source previews

`android-history-en.png`, `android-devices-en.png` and `android-settings-dark-en.png` are direct, unretouched emulator screenshots of the redesigned Flutter application, at 1080 × 2340. The history contains fictional sample text and a sample file; sync remains off, and no personal clipboard, contacts, notifications or credentials are used.

The emulator has its own disposable data partition. Capture with Android's `screencap -p` after the page settles. Do not redraw the actual interface through image generation. See Android design (local document: `docs/design/standards/ANDROID_DESIGN.md`) for implementation and interaction rules.
