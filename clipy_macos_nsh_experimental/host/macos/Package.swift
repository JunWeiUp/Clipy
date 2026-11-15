// swift-tools-version: 5.9
import PackageDescription
import Foundation
let relay = ProcessInfo.processInfo.environment["COMMON_RELAY_PATH"] ?? "../../../../common-relay/sdk/swift"
let package = Package(name: "ClipyNative", platforms: [.macOS(.v13)], products: [.executable(name: "clipy-native", targets: ["ClipyNative"])], dependencies: [.package(path: relay)], targets: [.executableTarget(name: "ClipyNative", dependencies: [.product(name: "CommonRelay", package: "swift")], linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("Vision"), .linkedFramework("Security"), .linkedFramework("IOKit"), .linkedFramework("AVFoundation")])])
