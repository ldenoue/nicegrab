// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FrameGrab",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "FrameGrab", targets: ["FrameGrab"])],
    targets: [.executableTarget(name: "FrameGrab")]
)
