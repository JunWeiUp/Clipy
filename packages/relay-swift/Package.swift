// swift-tools-version: 5.9
import PackageDescription

// A static product for the app's swiftc build; SDK implementation stays upstream.
let package = Package(
    name: "ClipyRelayDependencies",
    platforms: [.macOS(.v13)],
    products: [.library(name: "ClipyRelayDependencies", type: .static, targets: ["ClipyRelayDependencies"])],
    dependencies: [.package(url: "https://github.com/JunWeiUp/common-relay.git", exact: "0.1.3")],
    targets: [.target(name: "ClipyRelayDependencies", dependencies: [.product(name: "CommonRelay", package: "common-relay")])]
)
