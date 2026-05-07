import Foundation

/// Minimal geohash encoder. We use level-6 (~1.2km × 0.6km tile,
/// varies by latitude) for People Nearby — fine enough that two
/// users in the same hash are realistically within walking
/// distance, coarse enough that the server can't pinpoint anyone
/// inside it. The server stores the hash string opaquely; only the
/// client knows the full coordinates that produced it.
enum Geohash {
    private static let alphabet = Array("0123456789bcdefghjkmnpqrstuvwxyz")

    /// Decode a geohash back to its centre `(lat, lon)`. Inverse of
    /// `encode`. Returns the centre point of the cell, with
    /// precision determined by the hash length.
    static func decode(_ hash: String) -> (lat: Double, lon: Double, latErr: Double, lonErr: Double)? {
        var latRange: (low: Double, high: Double) = (-90, 90)
        var lonRange: (low: Double, high: Double) = (-180, 180)
        var even = true
        for ch in hash {
            guard let idx = alphabet.firstIndex(of: ch) else { return nil }
            for bit in (0..<5).reversed() {
                let v = (idx >> bit) & 1
                if even {
                    let mid = (lonRange.low + lonRange.high) / 2
                    if v == 1 { lonRange.low = mid } else { lonRange.high = mid }
                } else {
                    let mid = (latRange.low + latRange.high) / 2
                    if v == 1 { latRange.low = mid } else { latRange.high = mid }
                }
                even.toggle()
            }
        }
        return (
            (latRange.low + latRange.high) / 2,
            (lonRange.low + lonRange.high) / 2,
            (latRange.high - latRange.low) / 2,
            (lonRange.high - lonRange.low) / 2
        )
    }

    /// Eight neighbouring cells around `hash` at the same precision.
    /// Used by People Nearby so the discovery query covers the
    /// caller's tile plus its immediate ring — two users a couple
    /// hundred metres apart but on different sides of a hash
    /// boundary still find each other. Returns the original hash
    /// first followed by the eight neighbours.
    static func selfAndNeighbours(of hash: String) -> [String] {
        guard let dec = decode(hash) else { return [hash] }
        let length = hash.count
        let dLat = dec.latErr * 2
        let dLon = dec.lonErr * 2
        let offsets: [(Double, Double)] = [
            ( 0,  0),       // self
            ( 0, -dLon),    // W
            ( 0,  dLon),    // E
            (-dLat,  0),    // S
            ( dLat,  0),    // N
            (-dLat, -dLon), // SW
            (-dLat,  dLon), // SE
            ( dLat, -dLon), // NW
            ( dLat,  dLon), // NE
        ]
        var seen = Set<String>()
        var result: [String] = []
        for (latOff, lonOff) in offsets {
            let n = encode(lat: dec.lat + latOff, lon: dec.lon + lonOff, length: length)
            if seen.insert(n).inserted { result.append(n) }
        }
        return result
    }

    /// Encode `(lat, lon)` to a geohash of the given length. Length 6
    /// = 30 bits = ~1.2km. Length 7 = ~150m. Length 5 = ~5km.
    /// Standard interleaved-bit-bisection algorithm; this isn't
    /// performance-critical (one call per check-in) so the
    /// straightforward loop wins over fancier variants.
    static func encode(lat: Double, lon: Double, length: Int = 6) -> String {
        var latRange: (low: Double, high: Double) = (-90, 90)
        var lonRange: (low: Double, high: Double) = (-180, 180)
        var hash = ""
        var bits = 0
        var bit = 0
        var even = true
        while hash.count < length {
            if even {
                let mid = (lonRange.low + lonRange.high) / 2
                if lon >= mid {
                    bits = (bits << 1) | 1
                    lonRange.low = mid
                } else {
                    bits = bits << 1
                    lonRange.high = mid
                }
            } else {
                let mid = (latRange.low + latRange.high) / 2
                if lat >= mid {
                    bits = (bits << 1) | 1
                    latRange.low = mid
                } else {
                    bits = bits << 1
                    latRange.high = mid
                }
            }
            even.toggle()
            bit += 1
            if bit == 5 {
                hash.append(alphabet[bits])
                bits = 0
                bit = 0
            }
        }
        return hash
    }
}
