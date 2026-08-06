// Exercises the real mapping between a Message and the archive record: the
// round trip, the leanest possible line, and the pipe-joined media field.
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok {
        print("  ok   \(name)")
    } else {
        failures += 1
        print("  FAIL \(name) \(detail())")
    }
}

let enc = JSONEncoder()
let dec = JSONDecoder()
let me = 907_090_268

print("round trip, a message with everything set:")
let sent = Date(timeIntervalSince1970: 1_786_000_000)
let rich = Message(
    id: UUID(uuidString: "1A2B3C4D-1111-2222-3333-444444444444")!,
    thread: .group(id: 21),
    senderUIN: 911,
    isFromMe: false,
    kind: .video,
    text: "подпись",
    mediaID: "abc123|QlMmLqQKgMcL6RoTRaPtda5L5/5DMpwP2pMKxEqXMH0=",
    sentAt: sent,
    deliveryState: .sent,
    receivedWhileAway: true,
    deletedForEveryone: false,
    reactions: [911: "kolobok_smile", 333: "good"],
    thumbnailB64: "AAAA",
    durationSec: 12.5,
    ttlSeconds: 86400,
    forwardedFromName: "ɅV",
    replyToID: UUID(uuidString: "1A2B3C4D-9999-9999-9999-999999999999")!,
    replyToSnippet: "snippet",
    replyToAuthorName: "admin",
    editedAt: sent.addingTimeInterval(60),
    albumID: UUID(uuidString: "1A2B3C4D-5555-5555-5555-555555555555")!,
    fileName: "clip.mp4",
    fileMime: "video/mp4",
    fileSizeBytes: 4096,
    latitude: 55.75,
    longitude: 37.61,
    pollID: 7,
    isSpoiler: true,
)

let wire = try! enc.encode(BackupRecordMapping.toRecord(rich))
let back = BackupRecordMapping.toMessage(try! dec.decode(BackupRecordMapping.Record.self, from: wire), ownUIN: me)!

check("id", back.id == rich.id)
check("thread", back.thread == rich.thread)
check("sender", back.senderUIN == rich.senderUIN)
check("kind", back.kind == rich.kind)
check("text", back.text == rich.text)
check("mediaID keeps the pipe", back.mediaID == rich.mediaID, "got \(back.mediaID ?? "nil")")
check("sentAt", abs(back.sentAt.timeIntervalSince(rich.sentAt)) < 0.001)
check("reactions", back.reactions == rich.reactions)
check("thumb", back.thumbnailB64 == rich.thumbnailB64)
check("durationSec", back.durationSec == rich.durationSec)
check("ttlSeconds", back.ttlSeconds == rich.ttlSeconds, "got \(String(describing: back.ttlSeconds))")
check("forwardedFrom", back.forwardedFromName == rich.forwardedFromName)
check("replyToID", back.replyToID == rich.replyToID)
check("replySnippet", back.replyToSnippet == rich.replyToSnippet)
check("replyAuthor", back.replyToAuthorName == rich.replyToAuthorName)
check("editedAt", abs((back.editedAt ?? .distantPast).timeIntervalSince(rich.editedAt!)) < 0.001)
check("albumID", back.albumID == rich.albumID)
check("file", back.fileName == rich.fileName && back.fileMime == rich.fileMime && back.fileSizeBytes == rich.fileSizeBytes)
check("coords", back.latitude == rich.latitude && back.longitude == rich.longitude)
check("pollID", back.pollID == rich.pollID)
check("spoiler", back.isSpoiler == rich.isSpoiler)
check("restored is delivered", back.deliveryState == .delivered)

print("\nthe leanest line another client can write (no optional key at all):")
let lean = Data(#"{"id":"1A2B3C4D-0000-0000-0000-000000000001","group":21,"from_me":false,"sent_at":1786000000000,"body":"hi"}"#.utf8)
if let r = try? dec.decode(BackupRecordMapping.Record.self, from: lean),
   let m = BackupRecordMapping.toMessage(r, ownUIN: me) {
    check("survives a missing reactions key", m.reactions.isEmpty)
    check("kind falls back to text", m.kind == .text)
    check("no ttl", m.ttlSeconds == nil)
    check("sender falls back to the thread", m.senderUIN == 21)
} else {
    check("leanest line decodes", false)
}

print("\nrecords that cannot be a message here:")
for (name, json) in [
    ("no id", #"{"group":21,"body":"x"}"#),
    ("id is not a uuid", #"{"id":"not-a-uuid","group":21}"#),
    ("names neither thread", #"{"id":"1A2B3C4D-0000-0000-0000-000000000002","body":"x"}"#),
] {
    let r = try? dec.decode(BackupRecordMapping.Record.self, from: Data(json.utf8))
    check("\(name) is rejected", r.flatMap { BackupRecordMapping.toMessage($0, ownUIN: me) } == nil)
}

print("\n1:1 sender, and the system-notice kind Android spells differently:")
let dm = Message(thread: .peer(uin: 911), senderUIN: 911, isFromMe: false, kind: .systemNotice, text: "joined")
let dmWire = try! enc.encode(BackupRecordMapping.toRecord(dm))
let dmJSON = try! JSONSerialization.jsonObject(with: dmWire) as! [String: Any]
check("1:1 leaves sender out", dmJSON["sender"] == nil)
check("systemNotice goes out as Android's name", dmJSON["kind"] as? String == "system")
let dmBack = BackupRecordMapping.toMessage(try! dec.decode(BackupRecordMapping.Record.self, from: dmWire), ownUIN: me)!
check("and comes back as systemNotice", dmBack.kind == .systemNotice)
check("1:1 sender is the peer", dmBack.senderUIN == 911)

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
