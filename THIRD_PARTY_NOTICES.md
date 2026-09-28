# Third-party provenance and release review

## Release-blocking license review

The repository currently contains an MIT `LICENSE`. This does **not** establish
that the complete macOS application can be distributed under MIT alone.

`clipy_macos/Sources/Screenshot/` contains a modified port of
[sw33tLie/macshot](https://github.com/sw33tLie/macshot). The upstream
[LICENSE](https://github.com/sw33tLie/macshot/blob/main/LICENSE), checked on
2026-09-03, is GNU GPL version 3. The exact upstream revision and license at
the time of the import have not yet been recorded in this repository.

Before publishing a new combined macOS binary, the maintainer must:

- Identify and record the imported revision and its applicable license.
- Preserve the applicable license text, copyright notices and modification notices.
- Resolve the combined distribution terms and corresponding-source obligations,
  or obtain suitable separate permission, or remove/replace the port.
- Update `LICENSE`, the README and distributed notices to reflect that decision.

The current MIT text has deliberately **not** been replaced without a maintainer
decision. This notice records an unresolved provenance issue; it does not grant
permission, complete a license audit, or relicense anyone else's code.

## macshot adaptation

The port covers capture, annotation, recording, editing and related UI/services.
Local adaptations include `ScreenshotSessionCoordinator`, app integration
protocols/shims, Chinese localization, clipboard/history integration, and offline
build configuration. Keep these boundaries explicit when updating upstream code.

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
