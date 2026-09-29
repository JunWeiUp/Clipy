# Third-party provenance and notices

Screenshot module provenance: independently implemented by Clipy contributors.

The current `clipy_macos/Sources/NativeScreenshot/` uses Apple system APIs and
the separately listed BSD-licensed WebP encoder. The former
`clipy_macos/Sources/Screenshot/` tree is absent from current build inputs and
source releases. Historical commits and tags can still contain the earlier
[macshot](https://github.com/sw33tLie/macshot) GPLv3 code; distribution of
those historical revisions or binaries remains subject to their own licenses.
This notice concerns the current source tree and does not relicense history.

## libwebp (WebP screenshot export)

The macOS build statically links Google's libwebp 1.6.0 from the pinned archive
in `third_party/libwebp/`. Source URL, SHA-256, patent grant and build details
are recorded in that directory. Its BSD-3-Clause notice follows and is included
with the macOS application:

> Copyright (c) 2010, Google Inc. All rights reserved.
>
> Redistribution and use in source and binary forms, with or without
> modification, are permitted provided that the following conditions are
> met:
>
>   * Redistributions of source code must retain the above copyright
>     notice, this list of conditions and the following disclaimer.
>
>   * Redistributions in binary form must reproduce the above copyright
>     notice, this list of conditions and the following disclaimer in
>     the documentation and/or other materials provided with the
>     distribution.
>
>   * Neither the name of Google nor the names of its contributors may
>     be used to endorse or promote products derived from this software
>     without specific prior written permission.
>
> THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
> "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
> LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
> A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
> HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
> SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
> LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
> DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
> THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
> (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
> OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

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
- Apple system frameworks are linked from the developer's SDK, not vendored here.

This is a provenance inventory, not a claim that every dependency has been audited.
