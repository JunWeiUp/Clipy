#!/usr/bin/env bash

# Call after REPO_ROOT and BUILD_DIR are set. Builds the pinned, vendored
# libwebp encoder from source with the same architecture and deployment target
# as the app. The caller links both static archives by absolute path.
build_webp_static() {
  local archive="${REPO_ROOT}/third_party/libwebp/libwebp-1.6.0.tar.gz"
  local expected="93a852c2b3efafee3723efd4636de855b46f9fe1efddd607e1f42f60fc8f2136"
  local actual
  actual="$(shasum -a 256 "${archive}" | awk '{print $1}')"
  [ "${actual}" = "${expected}" ] || {
    printf 'libwebp source checksum mismatch\n' >&2
    return 1
  }

  local source_dir="${BUILD_DIR}/libwebp-1.6.0"
  local library_dir="${BUILD_DIR}/libwebp-build"
  tar -xzf "${archive}" -C "${BUILD_DIR}"
  cmake -S "${source_dir}" -B "${library_dir}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="${MACOS_ARCH}" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
    -DBUILD_SHARED_LIBS=OFF \
    -DWEBP_ENABLE_SIMD=OFF \
    -DWEBP_USE_THREAD=OFF \
    -DWEBP_BUILD_ANIM_UTILS=OFF \
    -DWEBP_BUILD_CWEBP=OFF \
    -DWEBP_BUILD_DWEBP=OFF \
    -DWEBP_BUILD_GIF2WEBP=OFF \
    -DWEBP_BUILD_IMG2WEBP=OFF \
    -DWEBP_BUILD_VWEBP=OFF \
    -DWEBP_BUILD_WEBPINFO=OFF \
    -DWEBP_BUILD_LIBWEBPMUX=OFF \
    -DWEBP_BUILD_WEBPMUX=OFF \
    -DWEBP_BUILD_EXTRAS=OFF
  cmake --build "${library_dir}" --config Release --target webp -j 4
  WEBP_STATIC_LIBRARY="${library_dir}/libwebp.a"
  SHARPYUV_STATIC_LIBRARY="${library_dir}/libsharpyuv.a"
  [ -s "${WEBP_STATIC_LIBRARY}" ] && [ -s "${SHARPYUV_STATIC_LIBRARY}" ] || {
    printf 'libwebp static archives are missing\n' >&2
    return 1
  }
}
