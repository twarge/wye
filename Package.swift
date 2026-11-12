// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Wye",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
        .visionOS(.v26)
    ],
    products: [
        // The app is built by Wye.xcodeproj, which links these products.
        .library(name: "GitKit", targets: ["GitKit"]),
        .library(name: "WyeUI", targets: ["WyeUI"]),
        // What the app shares with its widget and share extensions, which
        // link only this: no libgit2, no SwiftUI app.
        .library(name: "WyeShared", targets: ["WyeShared"])
    ],
    dependencies: [
        // SSH remotes: the protocol in Swift, over Network.framework, with
        // the primitives from CryptoKit. libgit2 is built without SSH.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.105.0"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.15.1"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.28.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "5.1.1")
    ],
    targets: [
        // libgit2, compiled from the Vendor/libgit2 submodule. It is GPLv2 with
        // a linking exception, which is why it stays a submodule: none of its
        // source is part of this repository.
        .target(
            name: "Clibgit2",
            path: "Vendor",
            exclude: [
                "libgit2/src/util/win32",
                "libgit2/src/util/hash/builtin.c",
                "libgit2/src/util/hash/mbedtls.c",
                "libgit2/src/util/hash/openssl.c",
                "libgit2/src/util/hash/win32.c",
                "libgit2/src/util/hash/rfc6234",
                "libgit2/src/util/CMakeLists.txt",
                "libgit2/src/util/git2_features.h.in",
                "libgit2/src/libgit2/CMakeLists.txt",
                "libgit2/src/libgit2/config.cmake.in",
                "libgit2/src/libgit2/experimental.h.in",
                "libgit2/src/libgit2/git2.rc",
                "libgit2/deps/llhttp/CMakeLists.txt",
                "libgit2/deps/llhttp/LICENSE-MIT",
                "libgit2/deps/xdiff/CMakeLists.txt"
            ],
            sources: [
                "Clibgit2/shim.c",
                "libgit2/src/libgit2",
                "libgit2/src/util",
                "libgit2/deps/llhttp",
                "libgit2/deps/xdiff"
            ],
            publicHeadersPath: "Clibgit2/include",
            cSettings: [
                .headerSearchPath("Clibgit2/config"),
                .headerSearchPath("libgit2/include"),
                .headerSearchPath("libgit2/src/libgit2"),
                .headerSearchPath("libgit2/src/util"),
                .headerSearchPath("libgit2/deps/llhttp"),
                .headerSearchPath("libgit2/deps/xdiff"),
                .define("SHA1DC_NO_STANDARD_INCLUDES", to: "1"),
                .define("SHA1DC_CUSTOM_INCLUDE_SHA1_C", to: "\"git2_util.h\""),
                .define("SHA1DC_CUSTOM_INCLUDE_UBC_CHECK_C", to: "\"git2_util.h\""),
                // Clang modules pull all of Darwin into every file, where
                // <search.h>'s `struct entry` collides with xdiff's own.
                // Warnings in vendored code are not ours to act on.
                .unsafeFlags(["-fno-modules", "-w"])
            ],
            linkerSettings: [
                .linkedLibrary("z"),
                .linkedLibrary("iconv"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security")
            ]
        ),
        .target(
            name: "GitKit",
            dependencies: [
                "Clibgit2",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: "Sources/GitKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "WyeUI",
            dependencies: ["GitKit", "WyeShared"],
            path: "Sources/WyeUI",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The status file, links and URL reading the extensions need,
        // with nothing heavier than Foundation.
        .target(
            name: "WyeShared",
            path: "Sources/WyeShared",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "WyeSharedTests",
            dependencies: ["WyeShared"],
            path: "Tests/WyeSharedTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The interface's logic that needs no window: filtering file events,
        // fuzzy matching, the repository list's store.
        .testTarget(
            name: "WyeUITests",
            dependencies: ["WyeUI"],
            path: "Tests/WyeUITests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "GitKitTests",
            dependencies: ["GitKit"],
            path: "Tests/GitKitTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
