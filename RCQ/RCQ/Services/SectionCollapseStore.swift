import Combine
import Foundation

/// Which chat-list sections the user has folded up.
///
/// ⚠ DEVICE-LOCAL, and that is the design rather than an omission. The sections
/// themselves live in the `sections` vault slot and are the same on every
/// device; the fold state deliberately sits outside it
/// (`docs/sections-design-2026-08-23.md`: "the collapse set stays
/// device-local"). A section folded away on a phone, where the list is the
/// whole screen and Offline is forty rows, must not fold on a desktop where the
/// window is a different shape. Web keeps the same thing in
/// `local-store.ts` `KEYS.collapsed`, Android in `LocalStores.sectionFlags`.
///
/// ⚠⚠ SCOPED BY ACCOUNT, like `SectionsStore` next door and unlike the
/// favourites / archive keys. A user section's id means something only inside
/// the account whose tree carries it, so a flat key files one account's fold
/// state against another account's sections, and hands the REAL account's fold
/// state to a decoy session. It is rebound wherever `SectionsStore` is rebound:
/// on an account switch, on entering a duress session, and on leaving one. The
/// scope is read in `init` as well, because the singleton is touched by the
/// chat list before anything gets a chance to bind it on a cold start.
///
/// ⚠ A CHOICE PER SECTION, not a set of collapsed ids, because a default is not
/// a constant here: Archive folds by default, Offline folds by default EXCEPT
/// in a decoy session (the seeded roster is small and folding it away leaves
/// the duress view looking empty, which is what the seeding exists to prevent).
/// Storing "the ids that differ from their default" -- the web shape -- or
/// seeding the set with today's defaults would freeze whichever default
/// happened to hold when it was written. Absent means the user never touched
/// that header, and the caller's default wins.
@MainActor
final class SectionCollapseStore: ObservableObject {
    static let shared = SectionCollapseStore()

    /// Section id -> the user's own choice. No entry = never toggled.
    @Published private(set) var choices: [String: Bool] = [:]

    /// The audio-rooms strip is a chat-list section with the same chevron and
    /// no record in the sections tree, so it needs an id of its own. It cannot
    /// collide with a real one: built-ins are `sys.*` and a user section is
    /// eight hex characters (`Sections.newSectionID`).
    static let audioRoomsID = "local.audiorooms"

    private static let prefix = "rcq.sections.collapsed.v1."
    private var key: String

    private init() {
        key = Self.prefix + (AppGroup.readActiveAccountID()?.uuidString ?? "none")
        load()
    }

    /// Re-point at the active account on an account switch and on both
    /// directions of the duress swap.
    func bind(accountID: UUID?) {
        key = Self.prefix + (accountID?.uuidString ?? "none")
        load()
    }

    func isCollapsed(_ id: String, default fallback: Bool) -> Bool {
        choices[id] ?? fallback
    }

    func set(_ id: String, collapsed: Bool) {
        guard choices[id] != collapsed else { return }
        choices[id] = collapsed
        save()
    }

    /// A deleted section leaves no preference behind. Without this the entry
    /// outlives the section that owned it, forever, and would decide the fold
    /// state of a later section that happened to draw the same id.
    func forget(_ id: String) {
        guard choices.removeValue(forKey: id) != nil else { return }
        save()
    }

    /// Burn-account hook.
    func wipe() {
        choices = [:]
        UserDefaults.standard.removeObject(forKey: key)
    }

    private func load() {
        let raw = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        choices = raw.compactMapValues { $0 as? Bool }
    }

    private func save() {
        UserDefaults.standard.set(choices, forKey: key)
    }
}
