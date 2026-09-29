# libwebp 1.6.0

This directory vendors the official `webmproject/libwebp` v1.6.0 source
archive for reproducible, static macOS builds of WebP screenshot output.

- Source: https://github.com/webmproject/libwebp/archive/refs/tags/v1.6.0.tar.gz
- SHA-256: `93a852c2b3efafee3723efd4636de855b46f9fe1efddd607e1f42f60fc8f2136`
- License: BSD-3-Clause (`COPYING`); see `PATENTS` for the patent grant.

The archive is unpacked only into the build's temporary directory. The
application links `libwebp.a` and `libsharpyuv.a`; no Homebrew dylib is used
at runtime.
