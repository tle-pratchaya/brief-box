// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BriefBox",
    platforms: [.macOS("26.0")],
    targets: [
        // ตัวอ่านอีเมล + ตัวแยกบรีฟ (ไม่มี UI ทดสอบได้)
        .target(name: "BriefCore"),
        // แอป SwiftUI
        .executableTarget(name: "BriefBox", dependencies: ["BriefCore"]),
        .testTarget(name: "BriefCoreTests", dependencies: ["BriefCore"]),
    ],
    swiftLanguageModes: [.v5]
)
