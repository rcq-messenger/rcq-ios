# RCQ for iOS

Privacy-first messenger. 9-digit numeric IDs, no phone number,
no email, no real name required. End-to-end encrypted via
[libsignal](https://github.com/signalapp/libsignal) (Double Ratchet
+ X3DH + sealed sender). SwiftUI + iOS 16+.

This repository is the **iOS client only**. The FastAPI backend
lives in a private repository and is not open-sourced — it carries
operational secrets (DigitalOcean API tokens, admin credentials,
APNs signing keys) that we are not in a position to publish. The
iOS client talks to `https://api.rcq.app`.

---

## Why we open-source the client

Until we can fund a paid third-party crypto audit (next year, when
finances allow), our security positioning rests on:

1. **Stock primitives only.** AES-GCM, X25519, Curve25519, Ed25519,
   HKDF — all routed through libsignal (vendored unmodified at
   `RCQ/Vendor/libsignal/`) or Apple's CryptoKit. No bespoke crypto.
2. **Open client.** Anyone can read what the app actually does with
   user keys, what it ships to the backend, and how envelopes are
   sealed. No hidden behavior, no telemetry sneak-ins.
3. **Public bug bounty.** See `Settings → Bug Bounty` inside the
   app for the disclosure policy and reward bands.

If you find a vulnerability, please disclose responsibly via the
in-app Bug Bounty surface (or `security@rcq.app`) **before**
filing a public issue here.

---

## Repository layout

```
rcq-ios/                             # repo root
├── RCQ/                             # iOS workspace
│   ├── RCQ/                         # Main app target
│   │   ├── Models/                  # Codable wire types + ThreadID / ItemKind / etc.
│   │   ├── Services/                # ContactService, MessageService, AudioRoomService, ...
│   │   ├── ViewModels/              # ChatViewModel, AppState, ...
│   │   ├── Views/                   # SwiftUI views (one screen per file mostly)
│   │   │   └── Components/          # Reusable cells, sheets, buttons
│   │   ├── Utils/                   # Crypto helpers, formatters, image compressor
│   │   ├── Resources/
│   │   │   ├── Assets.xcassets/     # All artwork (status icons, items, KOLOBOK packs)
│   │   │   ├── en.lproj/            # English Localizable.strings
│   │   │   ├── ru.lproj/            # Russian Localizable.strings
│   │   │   ├── Info.plist
│   │   │   └── PrivacyInfo.xcprivacy
│   │   └── RCQ.entitlements
│   ├── Vendor/                      # Vendored dependencies
│   │   ├── libsignal/               # Pinned upstream copy (Rust + Swift bindings)
│   │   └── Rcqbox.xcframework       # Embedded sing-box transport framework
│   ├── RCQNotificationService/      # NSE — decrypts envelope on push receipt
│   └── project.yml                  # xcodegen spec — generates RCQ.xcodeproj
├── .gitignore
├── LICENSE
├── NOTICE                           # Third-party attribution
└── README.md                        # this file
```

---

## Building locally

Prerequisites:
- Xcode 16+ (iOS 16 deployment target)
- [xcodegen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- Rust toolchain (only if you intend to rebuild libsignal from
  source; pre-built artifacts ship in the package)

```bash
git clone https://github.com/rcq-messenger/rcq-ios.git
cd rcq-ios
# One-time: rebuild libsignal's iOS xcframework binaries.
# The Rust source ships in the repo; the per-arch `.a` files
# don't, because each one is >100MB (GitHub's per-file limit).
# This step takes ~3-5 min depending on your machine.
cd RCQ/Vendor/libsignal/swift && ./build_ffi.sh --release && cd -
cd RCQ && xcodegen generate && cd -   # creates RCQ/RCQ.xcodeproj from project.yml
open RCQ/RCQ.xcodeproj
```

If you don't have the Rust toolchain yet:
```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
```

Bundle identifier `app.rcq.client` is wired to our Apple Developer
team. To run on a device under your own team, change
`PRODUCT_BUNDLE_IDENTIFIER` in `RCQ/project.yml` and re-run xcodegen.

The app talks to `https://api.rcq.app` by default. To point at a
local backend during development, set the `rcq.baseURL` UserDefault
on the simulator:

```bash
xcrun simctl spawn booted defaults write app.rcq.client \
  rcq.baseURL "http://localhost:8000"
```

---

## What's in here vs not

**Here:**
- Every line of UI, networking, encryption-glue, and persistence the
  iOS app runs at runtime.
- Localization tables (en + ru fully translated).
- Vendored libsignal source.

**Not here:**
- FastAPI backend (private repo, operational secrets).
- Web landing pages and `chat.rcq.app` web client (separate repo).
- App Store provisioning profiles, signing certificates, APNs auth
  key (per-team Apple-issued material).
- TestFlight / App Store Connect API tokens.

---

## License

**AGPL-3.0-or-later.** See [`LICENSE`](LICENSE) for full text.

We chose AGPL because we link directly to libsignal (also AGPL-3.0)
throughout the encryption layer — distributing under any more
permissive license would be incompatible. Same license Signal
itself ships under, and it matches what an "open client for trust"
project should be: anyone can fork it, but a fork that ships to
real users has to also publish its source.

Copyright stays with the project owner; the open license is
about transparency, not surrendering the brand.

The vendored [`RCQ/Vendor/libsignal/`](RCQ/Vendor/libsignal/)
directory is upstream libsignal under its own AGPL-3.0 license —
see `RCQ/Vendor/libsignal/LICENSE`. Unmodified beyond what's
required to build into the iOS target. See [`NOTICE`](NOTICE) for
the full third-party attribution list.

---

## Contact

- Security disclosure: `security@rcq.app` (or in-app Bug Bounty)
- General questions: GitHub issues on this repo
