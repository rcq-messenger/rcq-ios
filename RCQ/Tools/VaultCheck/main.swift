// The vault's derivation and sealed layout must be byte-identical to the web
// client's (web-chat/src/lib/vault.ts) and Android's (crypto/Vault.kt), or a
// contact list sealed on one device is unreadable on another. The vector was
// produced by the web implementation: identity_priv = 32 bytes of 0x01, slot
// name "contacts", version 7, nonce = 12 bytes of 0x07.
import CryptoKit
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

let ik = Data(repeating: 1, count: 32)
let slot = "78146d092b6e9be01f68451ea3dc0394"
let keyHex = "d7138589825968476d19a67ec265cf8962f93991e639002c31d6a841778a48a1"
let webBlob = Data(base64Encoded: "AQcHBwcHBwcHBwcHB7s8m3pcaUj8NByj0VVEpROZ4qW519dgA+zNDKqAqjDQfHP67JFiV5X5J8N1gw8MPSRiJuabp/x8Ky4qibIwJ/w9pYC4KADDbwPYs/53xO2AlXmbMG4lxZNKYwMHHoA6UqPQpdjWAyJk91X+fDXKA6foOMywFKXlrxQiE8qVNOgfmVLPanosS5SrFK85cthE1Vzh0gtQovujG1h6sbqf2bRE5zyGx/SkcbL5yZeX7lro9up2NkbzFKprxchpnlXcH/lpo+wlbiaibR8IDKgciNXcGzN+PS2mQMrCHW/yubyVbmRSg3UnYf6dzb5sX10kHTmwwyhpExj6rHRY/QXe0t3nGTGkl/2o9kcXYL1/+GNynpRmTZ+5DacLjSCjJ+pWmXavUvx7h/7Pw/B7rc/dUBy2Exy83KczrhcmWNVKS33cFkXbcSDO8SktVBLn3tjVGoaanRZnmxyrbj9WVtQr1y14cHLl/GimRlOLkvlPz5sYURLBN56p72LUrz5HUmDGZQFRObdA0nOKG2bdxfQobafNMJsg+2GIOX1qNMAdJwXkTFPYDTacUDRc4uRC3kRYjki89V6R2U0RlfrnrkAUH+oi354/uKMjb+dVgTNUsMIDlDqHUPJQgGoiIgB/zOxI0pJXqbBM8Vd8G42+Y7jvGURdT8C+0Xie6EgD9I7G7rV9N1/3NiLEbV4oizlQIbZJzA==")!
let plaintext = "{\"v\":1,\"c\":{\"1\":{\"a\":1,\"u\":1,\"n\":\"n1\"}},\"g\":{}}"

print("derivation:")
check("slot matches the web", Vault.slotId(identityPriv: ik, name: Vault.contacts) == slot)
check("key matches the web", Vault.slotKey(identityPriv: ik, slot: slot).map { String(format: "%02x", $0) }.joined() == keyHex)

print("sealed layout:")
let opened = try? Vault.open(identityPriv: ik, slot: slot, version: 7, blob: webBlob)
check("opens a blob the web sealed", opened.map { String(decoding: $0, as: UTF8.self) } == plaintext)
let nonce = try! ChaChaPoly.Nonce(data: Data(repeating: 7, count: 12))
let sealed = try? Vault.seal(identityPriv: ik, slot: slot, version: 7, plaintext: Data(plaintext.utf8), nonce: nonce)
check("seals exactly what the web seals", sealed == webBlob)
check("refuses the wrong version", (try? Vault.open(identityPriv: ik, slot: slot, version: 8, blob: webBlob)) == nil)
check("refuses the wrong slot", (try? Vault.open(identityPriv: ik, slot: Vault.slotId(identityPriv: ik, name: "other"), version: 7, blob: webBlob)) == nil)
check("refuses another identity", (try? Vault.open(identityPriv: Data(repeating: 2, count: 32), slot: slot, version: 7, blob: webBlob)) == nil)

print("size class:")
let a = try! Vault.seal(identityPriv: ik, slot: slot, version: 1, plaintext: Data(count: 10))
let b = try! Vault.seal(identityPriv: ik, slot: slot, version: 1, plaintext: Data(count: 400))
check("10 and 400 bytes seal to the same length", a.count == b.count)
check("and open to their own length", (try? Vault.open(identityPriv: ik, slot: slot, version: 1, blob: b))?.count == 400)
check("an empty plaintext round-trips", (try? Vault.open(identityPriv: ik, slot: slot, version: 1, blob: try! Vault.seal(identityPriv: ik, slot: slot, version: 1, plaintext: Data())))?.count == 0)

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
