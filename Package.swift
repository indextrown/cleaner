// swift-tools-version: 6.0
import PackageDescription

// 코어 라이브러리, CLI, 테스트. 앱은 Tuist 프로젝트(Projects/App)가 이 패키지의 CleanerCore를 써서 만든다.
let package = Package(
    name: "Cleaner",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CleanerCore", targets: ["CleanerCore"]),
        .executable(name: "cleaner", targets: ["cleaner"]),
    ],
    targets: [
        .target(name: "CleanerCore"),
        .executableTarget(name: "cleaner", dependencies: ["CleanerCore"]),
        .testTarget(name: "CleanerCoreTests", dependencies: ["CleanerCore"]),
    ]
)
