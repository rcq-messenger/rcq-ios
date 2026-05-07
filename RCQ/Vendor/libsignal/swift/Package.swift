// swift-tools-version:5.10

//
// Copyright 2020-2021 Signal Messenger, LLC.
// SPDX-License-Identifier: AGPL-3.0-only
//
// RCQ patch: upstream signalapp/libsignal v0.93.1 manifest, modified so
// SignalFfi resolves as a prebuilt xcframework instead of a systemLibrary
// (which assumed a Rust build pipeline on the consumer side). Differences:
//   - swift-tools 6.0 → 5.10 to match RCQ's iOS 15 baseline
//   - SignalFfi: .systemLibrary → .binaryTarget(path: libsignal_ffi.xcframework)
//   - swift-docc-plugin dep dropped (RCQ does not build libsignal docs)
//   - LibSignalClientTests target dropped (we don't run libsignal's own tests)
//
// The xcframework is rebuilt from this same checkout with:
//   CARGO_BUILD_TARGET=aarch64-apple-ios     bash swift/build_ffi.sh --release
//   CARGO_BUILD_TARGET=aarch64-apple-ios-sim bash swift/build_ffi.sh --release
//   xcodebuild -create-xcframework \
//     -library target/aarch64-apple-ios/release/libsignal_ffi.a     -headers ... \
//     -library target/aarch64-apple-ios-sim/release/libsignal_ffi.a -headers ... \
//     -output swift/libsignal_ffi.xcframework
//
// build_ffi.sh has its full-LTO block commented out by RCQ (LTO emits LLVM
// bitcode .o files that xcodebuild rejects); the boring-sys build script
// in ~/.cargo/git/checkouts/boring-.../boring-sys/build/main.rs is patched
// to drop "-fembed-bitcode" for the same reason.

import PackageDescription

let package = Package(
    name: "LibSignalClient",
    platforms: [
        .iOS(.v15),
    ],
    products: [
        .library(
            name: "LibSignalClient",
            targets: ["LibSignalClient"]
        )
    ],
    targets: [
        .binaryTarget(
            name: "SignalFfi",
            path: "libsignal_ffi.xcframework"
        ),
        .target(
            name: "LibSignalClient",
            dependencies: ["SignalFfi"],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
    ]
)
