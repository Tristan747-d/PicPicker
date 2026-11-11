// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PicPicker",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "picpicker", targets: ["PicPicker"])
    ],
    targets: [
        .executableTarget(
            name: "PicPicker",
            path: "Sources/PicPicker",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "PicPickerTests",
            dependencies: ["PicPicker"],
            path: "Tests/PicPickerTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
