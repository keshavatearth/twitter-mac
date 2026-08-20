// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TwitterMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "TwitterMac", targets: ["TwitterMac"])
    ],
    targets: [
        // Single executable target. The filter JavaScript is deliberately NOT a
        // SwiftPM resource bundle: scripts/build_app.sh copies Resources/userscripts
        // into Contents/Resources so they stay hand-editable inside a shipped .app,
        // and UserScripts.swift also honours a user override directory.
        .executableTarget(
            name: "TwitterMac",
            path: "Sources/TwitterMac",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("LocalAuthentication"),
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
