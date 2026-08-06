import CommonCrypto
import CryptoKit
import Foundation

/// The `.rcqbak` container: a stream of named entries, encrypted end to end
/// with a key derived from the account's 24-word recovery phrase.
///
/// Why a container of our own rather than an encrypted database dump: the three
/// clients keep their history in three different stores (SQLCipher on Android,
/// Core Data here, IndexedDB in the browser), so a dump taken on a phone would
/// simply not open anywhere else, and "took it on Android, restored it on an
/// iPhone" is the entire point of having this.
///
/// ⚠ Private keys are deliberately NOT in here. Identity travels by phrase; a
/// file that carried both the history and the keys would be a single object
/// that hands over the entire account, and people mail these to themselves.
///
/// The byte contract lives in `RCQ/docs/backup-format.md` and every line of it
/// is load-bearing. The three that are easiest to get wrong, and that this file
/// therefore states out loud:
///
///  * the 4-byte chunk length **includes** the 12-byte nonce;
///  * the additional data of a chunk is the header bytes **as read from the
///    file** followed by the chunk index as an Int64 little-endian;
///  * CryptoKit's `sealed.combined` is nonce‖ct‖tag and must NOT be written —
///    the format wants `ciphertext + tag` after a nonce it writes itself.
enum BackupFormat {

    static let magic = Data("RCQBAK1\n".utf8)
    static let version = 1

    /// 400k rounds, same as the panic-PIN vault: this runs once per export and
    /// once per restore, so the cost is invisible to the person and expensive
    /// for anyone brute-forcing a stolen file.
    static let rounds = 400_000
    static let chunkSize = 1 << 20
    /// Largest chunk any reader in the fleet accepts (1 MiB + nonce + tag +
    /// slack). Writing bigger produces a file Android refuses.
    static let maxChunk = (1 << 20) + 64
    private static let endMarker: Int32 = -1
    private static let tagLen = 16
    private static let nonceLen = 12

    struct BackupError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
        init(_ message: String) { self.message = message }
    }

    // MARK: - key

    /// Normalised so "Word  Word" and "word word" derive the same key: the
    /// phrase is typed by hand on the restoring device.
    ///
    /// ⚠ Split on ASCII whitespace only, and lowercase locale-independently.
    /// Swift's `lowercased()` is already locale-independent; `lowercased(with:
    /// .current)` in a Turkish locale would turn `i` into `ı` and quietly
    /// derive a different key than the other two clients.
    static func normalize(phrase: String) -> String {
        let ascii: Set<Character> = [" ", "\t", "\n", "\u{0B}", "\u{0C}", "\r"]
        return phrase
            .lowercased()
            .split(whereSeparator: { ascii.contains($0) })
            .joined(separator: " ")
    }

    static func deriveKey(phrase: String, salt: Data, rounds: Int = BackupFormat.rounds) -> SymmetricKey {
        let secret = Array(normalize(phrase: phrase).utf8)
        let saltBytes = [UInt8](salt)
        var out = Data(count: 32)
        out.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) in
            _ = CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                secret, secret.count,
                saltBytes, saltBytes.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                UInt32(rounds),
                buf.bindMemory(to: UInt8.self).baseAddress, 32,
            )
        }
        return SymmetricKey(data: out)
    }

    // MARK: - bytes

    private static func len(_ v: Int32) -> Data {
        var le = v.littleEndian
        return Data(bytes: &le, count: 4)
    }

    private static func readInt32(_ d: Data, _ off: Int) throws -> Int32 {
        guard off + 4 <= d.count else { throw BackupError("backup is truncated") }
        return d.subdata(in: off ..< off + 4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self).littleEndian }
    }

    private static func aad(_ header: Data, _ index: Int64) -> Data {
        var le = index.littleEndian
        return header + Data(bytes: &le, count: 8)
    }

    /// Entry names go into a JSON line built by hand, so the two characters
    /// that could break that line are escaped. Names are ASCII by contract.
    private static func escape(_ name: String) -> String {
        name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - writer

    /// Streaming writer. Entries go out one after another and nothing is held
    /// whole in memory beyond one chunk, which matters because the media of a
    /// busy account runs to gigabytes.
    final class Writer {
        private let handle: FileHandle
        private let key: SymmetricKey
        private let header: Data
        private var chunkIndex: Int64 = 0
        private var buf = Data()

        init(handle: FileHandle, phrase: String, uin: Int, createdAt: Date) {
            self.handle = handle
            var salt = Data(count: 16)
            _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
            key = BackupFormat.deriveKey(phrase: phrase, salt: salt)
            // Built by hand rather than through JSONEncoder so the field order
            // matches the other two clients byte for byte. Nothing depends on
            // the order (readers authenticate the bytes they read), but a file
            // that can be diffed against Android's is worth the four lines.
            let createdMs = Int64((createdAt.timeIntervalSince1970 * 1000).rounded())
            header = Data("""
            {"version":\(BackupFormat.version),"uin":\(uin),"created_at":\(createdMs),\
            "kdf":"pbkdf2-sha256","rounds":\(BackupFormat.rounds),\
            "salt":"\(salt.base64EncodedString())","cipher":"aes-256-gcm"}
            """.utf8)
            handle.write(BackupFormat.magic)
            handle.write(BackupFormat.len(Int32(header.count)))
            handle.write(header)
        }

        private func flushChunk() throws {
            guard !buf.isEmpty else { return }
            var nonce = Data(count: BackupFormat.nonceLen)
            _ = nonce.withUnsafeMutableBytes {
                SecRandomCopyBytes(kSecRandomDefault, BackupFormat.nonceLen, $0.baseAddress!)
            }
            let sealed = try AES.GCM.seal(
                buf,
                using: key,
                nonce: AES.GCM.Nonce(data: nonce),
                authenticating: BackupFormat.aad(header, chunkIndex),
            )
            // NOT `sealed.combined`: that is nonce‖ct‖tag, and the format wants
            // the nonce written separately ahead of ct‖tag.
            let body = sealed.ciphertext + sealed.tag
            handle.write(BackupFormat.len(Int32(BackupFormat.nonceLen + body.count)))
            handle.write(nonce)
            handle.write(body)
            chunkIndex += 1
            buf.removeAll(keepingCapacity: true)
        }

        private func raw(_ bytes: Data) throws {
            var off = 0
            while off < bytes.count {
                let take = min(bytes.count - off, BackupFormat.chunkSize - buf.count)
                buf.append(bytes.subdata(in: off ..< off + take))
                off += take
                if buf.count == BackupFormat.chunkSize { try flushChunk() }
            }
        }

        /// One entry: a JSON line naming it and giving its byte length, then the
        /// bytes. Deliberately dumb so the other clients can read it without a
        /// library.
        func entry(name: String, bytes: Data) throws {
            try raw(Data("{\"name\":\"\(BackupFormat.escape(name))\",\"size\":\(bytes.count)}\n".utf8))
            try raw(bytes)
        }

        func finish() throws {
            try flushChunk()
            handle.write(BackupFormat.len(BackupFormat.endMarker))
            try handle.synchronize()
        }
    }

    // MARK: - reader

    /// Reader over the whole file in memory. The browser made the same trade
    /// and for the same reason: correctness first, and an archive big enough to
    /// hurt here is one this client cannot have produced.
    final class Reader {
        private let data: Data
        private let phrase: String
        private(set) var uin: Int = 0
        private(set) var version: Int = 0

        private var key: SymmetricKey!
        private var header = Data()
        private var offset = 0

        init(data: Data, phrase: String) {
            self.data = data
            self.phrase = phrase
        }

        func open() throws {
            guard data.count >= BackupFormat.magic.count,
                  data.prefix(BackupFormat.magic.count) == BackupFormat.magic
            else { throw BackupError("not an RCQ backup") }
            offset = BackupFormat.magic.count

            let hlen = Int(try BackupFormat.readInt32(data, offset))
            offset += 4
            guard hlen >= 1, hlen <= 8192, offset + hlen <= data.count else {
                throw BackupError("backup header looks wrong")
            }
            header = data.subdata(in: offset ..< offset + hlen)
            offset += hlen

            guard let obj = try? JSONSerialization.jsonObject(with: header) as? [String: Any] else {
                throw BackupError("backup header looks wrong")
            }
            version = obj["version"] as? Int ?? 0
            guard version <= BackupFormat.version else {
                throw BackupError("this backup was made by a newer version")
            }
            guard let uinValue = obj["uin"] as? Int else { throw BackupError("backup header looks wrong") }
            uin = uinValue

            // The header says how the key was derived, so it is obeyed rather
            // than assumed. Getting this wrong fails the GCM tag and looks
            // exactly like a wrong phrase, which sends the person off to
            // re-check the one thing that was never at fault.
            let kdf = obj["kdf"] as? String ?? "pbkdf2-sha256"
            let cipher = obj["cipher"] as? String ?? "aes-256-gcm"
            guard kdf == "pbkdf2-sha256" else {
                throw BackupError("this backup uses a key derivation this version does not know: \(kdf)")
            }
            guard cipher == "aes-256-gcm" else {
                throw BackupError("this backup uses a cipher this version does not know: \(cipher)")
            }
            let kdfRounds = obj["rounds"] as? Int ?? BackupFormat.rounds
            guard kdfRounds >= 1, kdfRounds <= 10_000_000 else { throw BackupError("backup header looks wrong") }
            guard let saltB64 = obj["salt"] as? String, let salt = Data(base64Encoded: saltB64) else {
                throw BackupError("backup header looks wrong")
            }
            key = BackupFormat.deriveKey(phrase: phrase, salt: salt, rounds: kdfRounds)
        }

        /// Decrypt the whole entry stream. Kept separate from the framing so a
        /// wrong phrase reports itself before any parsing is attempted.
        private func plaintext() throws -> Data {
            var out = Data()
            var index: Int64 = 0
            while true {
                let n = Int(try BackupFormat.readInt32(data, offset))
                offset += 4
                if n == Int(BackupFormat.endMarker) { break }
                guard n > BackupFormat.nonceLen, n <= BackupFormat.maxChunk, offset + n <= data.count else {
                    throw BackupError("backup is damaged")
                }
                let nonce = data.subdata(in: offset ..< offset + BackupFormat.nonceLen)
                let body = data.subdata(in: offset + BackupFormat.nonceLen ..< offset + n)
                offset += n
                guard body.count > BackupFormat.tagLen else { throw BackupError("backup is damaged") }
                let ct = body.prefix(body.count - BackupFormat.tagLen)
                let tag = body.suffix(BackupFormat.tagLen)
                do {
                    let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ct, tag: tag)
                    out += try AES.GCM.open(box, using: key, authenticating: BackupFormat.aad(header, index))
                } catch {
                    // The only realistic causes are a wrong phrase and a
                    // tampered file, and the person can only act on the first.
                    throw BackupError("wrong recovery phrase, or the file is damaged")
                }
                index += 1
            }
            return out
        }

        /// Calls [onEntry] with the name and bytes of each entry, in the order
        /// they were written. An entry claiming more bytes than are present
        /// fails the whole file: quietly returning a short one is the "restore
        /// half a history" this format exists to rule out.
        func forEachEntry(_ onEntry: (String, Data) throws -> Void) throws {
            let plain = try plaintext()
            var q = 0
            while q < plain.count {
                guard let nl = plain[q...].firstIndex(of: 0x0A) else { throw BackupError("backup is damaged") }
                let line = plain.subdata(in: q ..< nl)
                q = nl + 1
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let name = obj["name"] as? String,
                      let size = obj["size"] as? Int,
                      size >= 0, q + size <= plain.count
                else { throw BackupError("backup is damaged") }
                try onEntry(name, plain.subdata(in: q ..< q + size))
                q += size
            }
        }
    }
}
