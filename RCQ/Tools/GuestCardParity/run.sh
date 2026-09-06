#!/bin/sh
# Pins the iOS guest-card digest to the island's own Python, byte for byte.
#
# Three clients and a server all hash a card, and the island stores only the
# digest. If any one of them computes it differently by so much as a trimmed
# byte, every card that client registers opens nothing — and the symptom is a
# stranger being told "no such number", which is exactly what a working
# refusal looks like. A silent, undebuggable failure across four codebases is
# worth a check that runs in two seconds.
#
#     iOS/RCQ/Tools/GuestCardParity/run.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
out=$(mktemp -d)

cat > "$out/main.swift" <<'SWIFT'
import Foundation
import CryptoKit

func hashCard(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return SHA256.hash(data: Data(trimmed.utf8)).map { String(format: "%02x", $0) }.joined()
}

// The same vectors the Android test pins, and the same expression the island
// uses: hashlib.sha256(s.strip().encode("utf-8")).hexdigest()
let cases = [
    ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
    ("MEIfP9Zs4nB2xQ7kL0vRtYwUeIoPaSdFgHjKlZxCvBn", "30f4b6368375ba344c2f252d7678d35a4be82aaa35cc3fa66b04e07437561c63"),
    ("кириллица-и-emoji-🙂", "0fbca81cf75143f47f14db58c3547d991838f92b55411431bff7e7dd1b8fbaf8"),
    ("  padded  ", "c7f9b538b93ce513f654b8d199e50252ae037c5bde542c132b04a42cd8b92ea0"),
]
var bad = 0
for (input, want) in cases {
    let got = hashCard(input)
    if got == want {
        print("  ok   \(input.prefix(24))")
    } else {
        bad += 1
        print("  FAIL \(input.prefix(24))\n       want \(want)\n       got  \(got)")
    }
}
// And the shape of a fresh card, which has to survive a URL fragment untouched.
var b = [UInt8](repeating: 0, count: 32)
_ = SecRandomCopyBytes(kSecRandomDefault, b.count, &b)
let card = Data(b).base64EncodedString()
    .replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "=", with: "")
if card.count == 43 && card.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) {
    print("  ok   a fresh card is 43 url-safe characters")
} else {
    bad += 1
    print("  FAIL card shape: \(card)")
}
if bad > 0 { exit(1) }
print("guest-card parity: iOS == island")
SWIFT

swiftc -O "$out/main.swift" -o "$out/parity"
"$out/parity"
