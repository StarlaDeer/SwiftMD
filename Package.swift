// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftMD",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NetMDKit", targets: ["NetMDKit"]),
        .executable(name: "SwiftMD", targets: ["SwiftMD"]),
    ],
    targets: [
        // atracdenc (LGPL-2.1, https://github.com/dcherednik/atracdenc at e16e9c6, the version
        // Web MiniDisc Pro uses): only the ATRAC3 encoder, fed from memory by shim.cpp.
        .target(
            name: "CAtracDEnc",
            exclude: ["atracdenc/LICENSE", "VENDORED.md"],
            cSettings: [.define("kiss_fft_scalar", to: "double")],
            cxxSettings: [.headerSearchPath("atracdenc"), .unsafeFlags(["-w"])]
        ),
        // ATRAC3 (LP2 / LP4) decoder ported from FFmpeg 7.1's libavcodec/atrac3.c (LGPL-2.1+),
        // for turning disc backups into playable files.
        .target(
            name: "CAtrac3Dec",
            exclude: ["LICENSE"],
            linkerSettings: [.linkedFramework("Accelerate")]
        ),
        .target(
            name: "NetMDKit",
            dependencies: ["CAtracDEnc", "CAtrac3Dec"],
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("IOUSBHost")]
        ),
        .executableTarget(name: "SwiftMD", dependencies: ["NetMDKit"], resources: [.copy("Resources/AppIcon.png")]),
        .executableTarget(name: "netmdcli", dependencies: ["NetMDKit"]),
        .testTarget(name: "NetMDKitTests", dependencies: ["NetMDKit"], resources: [.copy("Fixtures")]),
    ],
    cxxLanguageStandard: .cxx17
)
