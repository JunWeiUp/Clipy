#!/usr/bin/env bash
# Source from the app build or test script. No installation or credential changes.
common_relay_swift() {
  local relay_root="$1" relay_arch="$2" relay_package relay_bin
  relay_package="${relay_root}/vendor/common-relay/swift"
  swift build --package-path "${relay_package}" --configuration release --triple "${relay_arch}-apple-macosx13.0" --product CommonRelay >&2
  relay_bin="$(swift build --package-path "${relay_package}" --configuration release --triple "${relay_arch}-apple-macosx13.0" --show-bin-path)"
  # SwiftBuild puts modules at the product root; native SwiftPM uses Modules/.
  # Native SwiftPM also leaves binary-target headers in the XCFramework.
  COMMON_RELAY_COMPILE_FLAGS=(-I "${relay_bin}" -I "${relay_bin}/Modules"
    -I "${relay_bin}/include/Clibsodium"
    -I "${relay_package}/.build/checkouts/swift-sodium/Clibsodium.xcframework/macos-arm64_arm64e_x86_64/Headers/Clibsodium")
  COMMON_RELAY_LINK_FLAGS=(-L "${relay_bin}" -lCommonRelay -lsodium)
}
