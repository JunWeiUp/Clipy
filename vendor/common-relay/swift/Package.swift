// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "CommonRelay",
    platforms: [.macOS(.v13), .iOS(.v15)],
    products: [.library(name: "CommonRelay", type: .static, targets: ["CommonRelay"])],
    dependencies: [.package(url: "https://github.com/jedisct1/swift-sodium.git", exact: "0.11.0")],
    targets: [.target(name: "CommonRelay", dependencies: [.product(name: "Clibsodium", package: "swift-sodium")])]
)
