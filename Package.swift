// swift-tools-version: 5.10
import PackageDescription

// GUI（SwiftUI/AppKit/WebKit）仅 macOS；Windows 上只构建核心库与 CLI。
var packageProducts: [Product] = [
    .library(name: "MoongateMobileCore", targets: ["MoongateMobileCore"]),
    .executable(name: "moongate-cli", targets: ["moongate-cli"]),
]

var packageTargets: [Target] = [
    // 纯契约层：不依赖桌面 Process/Homebrew/AppKit/Windows 实现，供核心逻辑复用。
    .target(name: "MoongateMobileCore", path: "Sources/MoongateMobileCore"),
    // 核心逻辑：链接嗅探 + yt-dlp 封装 + 翻译 + 烧录，可被 App 和 CLI 共用
    .target(name: "MoongateCore", dependencies: ["MoongateMobileCore"], path: "Sources/MoongateCore"),
    // 命令行工具：跨平台（macOS / Windows），不开 GUI 也能走全流程
    .executableTarget(
        name: "moongate-cli",
        dependencies: ["MoongateCore"],
        path: "Sources/moongate-cli"
    ),
    .testTarget(
        name: "MoongateCoreTests",
        dependencies: ["MoongateCore", "MoongateMobileCore"],
        path: "Tests/MoongateCoreTests"
    ),
]

#if os(macOS)
packageProducts.append(
    .executable(name: "Moongate", targets: ["Moongate"])
)

packageTargets.append(
    // SwiftUI 图形界面 App（仅 macOS）
    .executableTarget(
        name: "Moongate",
        dependencies: ["MoongateCore"],
        path: "Sources/Moongate"
    )
)
#endif

let package = Package(
    name: "Moongate",
    platforms: [.macOS(.v14)],
    products: packageProducts,
    targets: packageTargets
)
