# Third-party provenance and licenses

## macOS application: GNU GPL version 3

The macOS application combines Clipy-authored MIT-licensed code with a modified
port of [sw33tLie/macshot](https://github.com/sw33tLie/macshot). The combined
macOS application is distributed under GNU GPL version 3; it is **not** an
MIT-only application. The complete GPLv3 text is in `LICENSE.GPL-3.0`, both in
this repository and in `ClipyClone.app/Contents/Resources/`. Clipy-authored
code retains its MIT terms in `LICENSE`. The Android and Windows applications
do not include this macshot port.

The upstream reference is [macshot revision
`baae5487e0c3fb46350c38a8052a81f00a8497d2`](https://github.com/sw33tLie/macshot/tree/baae5487e0c3fb46350c38a8052a81f00a8497d2),
the latest upstream commit before Clipy's import commit
`736ba8fd51e1703b3d89563404cbb7267a4a89c4`. At import, 77 of 85 files
with matching relative paths had identical Git blobs; eight were locally
adapted, and nine integration files were added. The original local checkout's
Git HEAD was not retained, so this is the identified reference revision, not
an assertion that every imported file was byte-for-byte identical. Its
[`LICENSE`](https://github.com/sw33tLie/macshot/blob/baae5487e0c3fb46350c38a8052a81f00a8497d2/LICENSE)
is GPLv3 and matches the bundled `LICENSE.GPL-3.0` exactly. Upstream authors
recorded in Git history include sw33tLie, Maciej Chojnacki, anten-ka, fxzer,
vo1x, Oleksandr Honcharov, PINKIIILQWQ, Ted G. Freitas, Tony Xu and
lubabs770; their authorship is preserved by the upstream history.

**Modification notice (2026-09-29):** Clipy adapted capture, annotation,
recording, editing and related services into `clipy_macos/Sources/Screenshot/`.
Changes include `ScreenshotSessionCoordinator`, app integration shims, Chinese
localization, clipboard/history integration, the offline build configuration,
and subsequent fixes recorded in this repository's Git history. Clipy does not
claim authorship of the imported upstream code.

The corresponding source for a release is this repository at that release's
`vX.Y.Z` tag, including the screenshot sources, build scripts and notices.
GitHub's release page provides source ZIP and tar archives at the tag.

## Other dependencies

- `clipy_macos/Resources/token-prices-seed.json` is a slim snapshot of [LiteLLM's model pricing data](https://github.com/BerriAI/litellm/blob/main/model_prices_and_context_window.json) (Copyright 2023 Berri AI, MIT license). `token-prices-overrides.json` is adapted from the [TokenTracker](https://github.com/xiufengsun/TokenTracker) curated overrides (Copyright 2026 xiufengsun, MIT license). Clipy uses these data files only; it does not embed or start either project.

  LiteLLM MIT notice (retained for the bundled price snapshot):

  > MIT License
  >
  > Copyright (c) 2023 Berri AI
  > Permission is hereby granted, free of charge, to any person obtaining a copy
  > of this software and associated documentation files (the "Software"), to deal
  > in the Software without restriction, including without limitation the rights
  > to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
  > copies of the Software, and to permit persons to whom the Software is
  > furnished to do so, subject to the following conditions:
  > The above copyright notice and this permission notice shall be included in all
  > copies or substantial portions of the Software.
  > THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
  > IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
  > FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
  > AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
  > LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
  > OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
  > SOFTWARE.

  TokenTracker MIT notice (retained for the adapted price data):

  > MIT License
  >
  > Copyright (c) 2026 xiufengsun
  >
  > Permission is hereby granted, free of charge, to any person obtaining a copy
  > of this software and associated documentation files (the "Software"), to deal
  > in the Software without restriction, including without limitation the rights
  > to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
  > copies of the Software, and to permit persons to whom the Software is
  > furnished to do so, subject to the following conditions:
  >
  > The above copyright notice and this permission notice shall be included in all
  > copies or substantial portions of the Software.
  >
  > THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
  > IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
  > FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
  > AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
  > LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
  > OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
  > SOFTWARE.

- Flutter/Dart dependencies are declared in `clipy_android/pubspec.yaml` and
  pinned transitively by `pubspec.lock`. Retain Flutter's generated dependency
  license data in distributed applications.
- AndroidX dependencies are declared in the Android Gradle files. Include their
  required notices when distributing Android builds.
- `GifskiExporter.swift` optionally invokes a separately installed
  [gifski](https://github.com/ImageOptim/gifski) executable. This repository's
  build script does not bundle that executable. Review its license before doing so.
- Apple system frameworks are linked from the developer's SDK, not vendored here.

This is a provenance inventory, not a claim that every dependency has been audited.
