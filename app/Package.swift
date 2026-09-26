// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CornixHUD",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CornixHUD",
            path: "Sources/CornixHUD",
            linkerSettings: [
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("IOKit"),
            ]
        ),
    ],
    // CoreBluetooth and IOKit deliver callbacks through C function pointers and
    // Objective-C delegates on the main run loop; Swift 6 strict isolation adds
    // ceremony there without catching anything real in an app this size.
    swiftLanguageModes: [.v5]
)
