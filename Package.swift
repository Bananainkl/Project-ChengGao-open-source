// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ChengGao",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "ChengGao", targets: ["ChengGao"])
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite"
        ),
        .binaryTarget(
            name: "whisper",
            path: "Frameworks/whisper.xcframework"
        ),
        .executableTarget(
            name: "ChengGao",
            dependencies: ["whisper", "CSQLite"],
            path: "Sources/ChengGao"
        ),
        .testTarget(
            name: "ChengGaoTests",
            dependencies: ["ChengGao"],
            path: "Tests/ChengGaoTests"
        )
    ]
)
