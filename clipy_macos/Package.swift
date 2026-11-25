// swift-tools-version: 5.9
import PackageDescription

// Local SwiftPM manifest for fast incremental development builds and IDE indexing
// (`swift build --package-path clipy_macos`).
// Release/local signed .app bundling continues to use build_macos_app.sh / build_macos_local.sh.
let package = Package(
    name: "ClipyClone",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ClipyClone", targets: ["ClipyClone"])
    ],
    dependencies: [
        .package(url: "https://github.com/JunWeiUp/common-relay.git", exact: "0.2.3")
    ],
    targets: [
        .executableTarget(
            name: "ClipyClone",
            dependencies: [
                .product(name: "CommonRelay", package: "common-relay")
            ],
            path: "Sources",
            exclude: [
                "Screenshot/README.md",
                "Sync/README.md"
            ],
            swiftSettings: [
                .define("OFFLINE")
            ],
            linkerSettings: [
                .linkedLibrary("compression"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Carbon"),
                .linkedFramework("IOKit"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Security"),
                .linkedFramework("Vision"),
                .linkedFramework("CoreImage"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("PDFKit"),
                .linkedFramework("WebKit"),
                .linkedFramework("Quartz"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreMedia")
            ]
        )
    ]
)
