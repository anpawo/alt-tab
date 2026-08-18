// swift-tools-version: 6.0
import PackageDescription


let package = Package(
    name: "alt-tab",
    platforms: [.macOS(.v14)],
    targets: [
        // Imports neither AppKit nor Dispatch. The missing imports are the enforcement: the
        // compiler holds the boundary so discipline does not have to.
        .target(
            name: "SwitchCore",
            path: "Sources/SwitchCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "alt-tab",
            dependencies: ["SwitchCore"],
            path: "Sources/AltTab",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // `swift test` cannot run here: without Xcode installed there is no XCTest to load the
        // .xctest bundle it produces, and it exits 0 having run nothing — a green that means
        // silence. swift-testing itself ships inside the Command Line Tools but its runner does
        // not. So the checks are an ordinary executable: `swift run check`, no framework, no
        // dependency, and it fails loudly on a machine with no developer tools at all.
        .executableTarget(
            name: "check",
            dependencies: ["SwitchCore"],
            path: "Sources/check",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
