# Product screenshots

English and Chinese screenshots of the current source build use fictional example content. The native panel and Token Usage snapshots are rendered by the macOS core test executable without reading the user's clipboard history, agent logs or snippets. The older History, Snippets and Preferences captures also use isolated example content.

The README begins with the cross-device concept artwork in `../readme/connected-hero.webp`. Its source and built-in imagegen prompt are documented in [../readme/PROMPTS.md](../readme/PROMPTS.md).

Mac gallery order in both README files:

1. `macos-panel-en.png` / `macos-panel-zh.png` — current 520 × 640 pt native menu-bar panel: top search, scrollable hidden icons, compact today's Token summary and history.
2. `macos-history-showcase.webp` and `macos-snippets-showcase.webp` — side-by-side History and Snippet Library stories.
3. `macos-token-usage-en.png` / `macos-token-usage-zh.png` — current native daily Token Usage window with fictional Agent totals.
4. `macos-preferences-showcase.webp` — continuous settings, inside an expandable detail.

The History, Snippets and Preferences showcases have quality-90 WebP delivery copies to reduce README loading cost. Their PNG originals remain available. Image encoding does not alter the illustrated composition. The panel and Token Usage images are direct native snapshots without decorative editing.

The older showcase images use AI-assisted presentation styling: a shared ivory, pale blue and sage paper illustration background, headings and soft shadows. They are visual presentations, not pixel-exact UI references. Each README showcase links to its original `macos-*-en.png` application capture, which preserves the actual controls, typography and content. `macos-menu-showcase.webp` and `macos-menu-en.png` remain as the previous classic-menu reference but are no longer the main README illustration. No private contacts, credentials, prompts or device history are included.

`gallery-background.png` is the shared decorative illustration, generated with the built-in imagegen tool. The final presentation prompts are in [PROMPTS.md](PROMPTS.md). Keep original captures when regenerating the showcase images.

Regenerate panel and Token Usage fixtures with `CLIPY_PANEL_SNAPSHOT_DIR=/tmp/clipy-panel-snapshots CLIPY_TOKEN_SNAPSHOT_DIR=/tmp/clipy-token-snapshots bash scripts/test_macos_core.sh`. Copy `english-history.png` and `light-history.png` from the panel directory, and `light-populated-en.png` and `light-populated.png` from the Token directory, to the respective README assets. Keep both README files in sync when replacing images. Screenshots describe the source build and may include changes not yet in a published release.

## Android source previews

`android-history-en.png`, `android-devices-en.png` and `android-settings-dark-en.png` are direct, unretouched emulator screenshots of the redesigned Flutter application, at 1080 × 2340. The history contains fictional sample text and a sample file; sync remains off, and no personal clipboard, contacts, notifications or credentials are used.

The emulator has its own disposable data partition. Capture with Android's `screencap -p` after the page settles. Do not redraw the actual interface through image generation. See [Android design](../../docs/ANDROID_DESIGN.md) for implementation and interaction rules.
