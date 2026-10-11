import Foundation

/// The two rules of a room-log drain that report 981 was about, kept pure so
/// Tools/GroupLogStallCheck drives them against this very source: when a row
/// that will not open is given up on (`GroupLogStall`), and how a drain walks
/// past a room such a row is holding (`GroupLogWalk`). What counts as the
/// row's fault, and where the records are kept, is MessageService's half.

/// A row in front of its room's cursor that keeps failing to open. One per
/// room, kept on disk per account: a row that fails on a short visit to the
/// app has to be counted across launches, or it is struck once per launch,
/// forgotten with the process, and holds its room until the island's log
/// drops it thirty days later.
struct GroupLogStall: Codable, Equatable {
    let seq: Int
    /// How it failed last (`GroupLogStall.way(of:)`).
    var way: String
    /// Drains in a row it failed the SAME way.
    var strikes: Int
    /// Drains in a row it failed at all. A row that fails a different way
    /// each time is still a row that does not open.
    var drains: Int
    /// The last drain that counted it. Drain numbers outlive the process, so
    /// a drain in a new launch is never mistaken for the one that counted.
    var drain: Int
    /// Given up on and acked past as unreadable here. Kept until the room is
    /// seen without it, so an ack that did not land does not start the count
    /// over.
    var writtenOff: Bool

    /// Drains in a row a row may fail the same way before it is given up on.
    /// The same three as Android's `GroupLogPage.FAIL_DRAINS`.
    static let sameWayLimit = 3
    /// Drains in a row a row may fail at all before it is given up on.
    static let anyWayLimit = 6

    /// The row at [seq] failed [way] in [drain], and it was the row's fault
    /// (never call this for a store that could not be read, a locked phone, or
    /// a sender still being looked up). [prev] is what was kept for its room.
    /// A drain is counted once however many of its pages served the row.
    static func strike(_ prev: GroupLogStall?, seq: Int, way: String, drain: Int) -> GroupLogStall {
        guard var next = prev, next.seq == seq else {
            return GroupLogStall(seq: seq, way: way, strikes: 1, drains: 1, drain: drain, writtenOff: false)
        }
        if next.writtenOff || next.drain == drain { return next }
        next.strikes = next.way == way ? next.strikes + 1 : 1
        next.drains += 1
        next.way = way
        next.drain = drain
        next.writtenOff = next.strikes >= sameWayLimit || next.drains >= anyWayLimit
        return next
    }

    /// How an error failed, without what it carried: the case of an enum
    /// (`missingPreKey`, not `missingPreKey(17)`), the domain and code of an
    /// NSError, digits masked. A row that keeps failing in the same place
    /// gets the same answer every time, so its strikes add up.
    static func way(of error: Error) -> String {
        let type = String(reflecting: Swift.type(of: error))
        let name: String
        if type == "NSError" || type.hasSuffix(".NSError") {
            let ns = error as NSError
            name = "\(ns.domain)/\(ns.code)"
        } else {
            name = String(String(describing: error).prefix { $0 != "(" }.prefix(80))
        }
        let masked = String(name.map { $0.isNumber ? "#" : $0 })
        return "\(type).\(masked)"
    }
}

/// How one drain walks an island's room log.
///
/// ⚠⚠ The fetch reads every room from where THIS device's cursor stands, and
/// only an ack moves it. A room a row is holding is therefore served from that
/// row on every page: an island that fills a page room by room (all of them,
/// before 2026.10.12) gives a stuck room with a long tail every page, and the
/// rooms after it were never served at all; one that shares the page still
/// serves the stuck room the same first rows, and the rest of its tail never.
/// The walk takes such a room out of the main walk and reads it separately,
/// from past what this drain already read (`after`, which never moves the
/// cursor), so the others go on being acked and every row of the stuck one
/// still lands while its count runs (report 981). Nothing read ahead is ever
/// acked: the cursor stays in front of the row until it opens or is given up.
struct GroupLogWalk {
    struct Room: Encodable, Equatable {
        let gid: Int
        /// Read from past here instead of from this device's cursor. Omitted
        /// from the JSON when nil: the island's cursor.
        let after: Int?
    }

    /// Pages one drain fetches at most, main walk and reading ahead together.
    static let maxPages = 20

    private(set) var pages = 0
    /// Every room the island named (the keys of its `cursors`).
    private var rooms = Set<Int>()
    /// Rooms a row is holding, by the island's id: the highest seq this drain
    /// has read in each.
    private(set) var stuck: [Int: Int] = [:]
    /// Stuck rooms whose every row this drain already read: they got stuck on
    /// a page the island had nothing more for. Nothing to read ahead there.
    private var readToEnd = Set<Int>()
    /// The main walk is over; the stuck rooms are being read ahead.
    private(set) var readingAhead = false

    /// The rooms the next fetch names: nil for every room, from the island's
    /// cursors (the first page, and every page while nothing is stuck).
    var request: [Room]? {
        if readingAhead {
            return stuck.keys.filter { !readToEnd.contains($0) }.sorted().map { Room(gid: $0, after: stuck[$0]) }
        }
        guard !stuck.isEmpty else { return nil }
        return rooms.subtracting(stuck.keys).sorted().map { Room(gid: $0, after: nil) }
    }

    /// A page went through ingest, and its ack, if it had one, landed.
    /// [served]: per room, the highest seq the page carried. [named]: the
    /// rooms in its `cursors`. [blocked]: the rooms a row stopped in front of
    /// (ignored while reading ahead: those rows get their count when the
    /// cursor reaches them). [moved]: the ack moved a cursor. Returns whether
    /// to fetch again.
    mutating func took<S: Sequence>(
        served: [Int: Int], named: S, more: Bool, blocked: Set<Int>, moved: Bool
    ) -> Bool where S.Element == Int {
        pages += 1
        if readingAhead {
            var advanced = false
            for (gid, seq) in served {
                guard let at = stuck[gid], seq > at else { continue }
                stuck[gid] = seq
                advanced = true
            }
            // Only while it gets somewhere: the same page twice would be the
            // same rows twice.
            return more && advanced && pages < Self.maxPages
        }
        rooms.formUnion(named)
        var newlyStuck = Set<Int>()
        for gid in blocked {
            if stuck[gid] == nil { newlyStuck.insert(gid) }
            stuck[gid] = max(stuck[gid] ?? 0, served[gid] ?? 0)
        }
        // `more` is for the whole page: without it, every room the page
        // named came whole.
        if !more { readToEnd.formUnion(newlyStuck) }
        guard pages < Self.maxPages else { return false }
        // Again while the island has more and the next page is not this one:
        // an ack moved a cursor, or a stuck room left the list. With neither,
        // the island would hand out this very page again.
        if more, moved || !newlyStuck.isEmpty, !rooms.subtracting(stuck.keys).isEmpty { return true }
        guard stuck.keys.contains(where: { !readToEnd.contains($0) }) else { return false }
        readingAhead = true
        return true
    }
}
