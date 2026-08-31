// swift-tools-version:5.9
//
// WebRTC, fetched from OUR OWN mirror instead of a GitHub release asset.
//
// ⚠⚠ WHY THIS PACKAGE EXISTS. WebRTC reaches this project as a SwiftPM
// `binaryTarget`, and upstream (github.com/stasel/WebRTC) serves the 43MB
// archive from a GitHub release asset, which redirects to
// release-assets.githubusercontent.com. That host is precisely the kind of
// transit RU carriers throttle or drop, and SwiftPM has no retry worth the
// name: the download fails, Xcode reports a missing WebRTC.xcframework, and
// the build is dead. It bites every machine with a cold artifact cache, which
// is a fresh clone, a new contributor, or anyone who cleaned DerivedData -
// and it has cost the founder several builds. Nothing about it is one-off,
// which is why the answer is not "resolve again".
//
// dl.rcq.app is the same Cloudflare-fronted host the APKs and desktop builds
// are served from, for the same reason and by the same people.
//
// ★ This adds NO trust. The checksum below is the one UPSTREAM publishes for
// this exact release, and SwiftPM verifies it after downloading: if our mirror
// ever served different bytes, resolution would fail rather than hand anyone a
// swapped media stack. The mirror is a road, not an authority.
//
// Bumping to a new WebRTC release, in order:
//   1. take the release's own url + checksum from stasel/WebRTC Package.swift;
//   2. download that archive and verify the checksum yourself;
//   3. upload it to /var/www/rcq/spm/ on the flagship (the /spm path is in the
//      dl.rcq.app allowlist in deploy/Caddyfile);
//   4. update the version in the filename and the checksum here.
// Never point this at a file whose checksum you have not checked by hand.
import PackageDescription

let package = Package(
    name: "WebRTC",
    platforms: [.iOS(.v13), .macOS(.v11)],
    products: [
        .library(name: "WebRTC", targets: ["WebRTC"]),
    ],
    targets: [
        .binaryTarget(
            name: "WebRTC",
            url: "https://dl.rcq.app/spm/WebRTC-M147.xcframework.zip",
            checksum: "49f9b1713432c19f408e3218fc8526c7692fafca5869f7ec5f5991614276ed40"
        ),
    ]
)
