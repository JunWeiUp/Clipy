# Product screenshots

English screenshots of the current source build, captured on macOS using fictional local example content. The preview uses isolated storage and does not read the user’s clipboard history or snippets.

The README begins with the cross-device concept artwork in `../readme/connected-hero.webp`. Its source and built-in imagegen prompt are documented in [../readme/PROMPTS.md](../readme/PROMPTS.md).

Mac gallery order in both README files:

1. `macos-menu-showcase.webp` — Menu Bar: history, word lookup, snippets and everyday tools.
2. `macos-history-showcase.webp` and `macos-snippets-showcase.webp` — side-by-side History and Snippet Library stories.
3. `macos-preferences-showcase.webp` — continuous settings, inside an expandable detail.

The menu, history, snippets and preferences have quality-90 WebP delivery copies to reduce README loading cost. Their PNG originals remain available. Image encoding does not alter the illustrated composition.

The showcase images use AI-assisted presentation styling: a shared ivory, pale blue and sage paper illustration background, headings and soft shadows. They are visual presentations, not pixel-exact UI references. Each README image links to its original `macos-*-en.png` application capture, which preserves the actual controls, typography and content. The original window captures exclude the operating system title bar and screen-sharing indicator; the menu capture includes the complete native menu. No private contacts, credentials or device history are included.

`gallery-background.png` is the shared decorative illustration, generated with the built-in imagegen tool. The final presentation prompts are in [PROMPTS.md](PROMPTS.md). Keep original captures when regenerating the showcase images.

Keep both README files in sync when replacing these images. Screenshots describe the source build and may include changes not yet in a published release.

## Android source previews

`android-history-en.png`, `android-devices-en.png` and `android-settings-dark-en.png` are direct, unretouched emulator screenshots of the redesigned Flutter application, at 1080 × 2340. The history contains fictional sample text and a sample file; sync remains off, and no personal clipboard, contacts, notifications or credentials are used.

The emulator has its own disposable data partition. Capture with Android's `screencap -p` after the page settles. Do not redraw the actual interface through image generation. These Android changes are a working source preview, not part of the published v1.0.18 packages. See [Android design](../../docs/ANDROID_DESIGN.md) for implementation and interaction rules.
