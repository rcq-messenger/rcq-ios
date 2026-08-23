import Foundation

/// Singleton owning the local account roster. Persists as JSON in
/// UserDefaults, exposes the active account via `@Published`. Every
/// singleton that touches per-account storage (S2 onward: Keychain,
/// MessageDB, APIClient base URL, etc.) reads
/// `AccountManager.shared.active` instead of going to legacy
/// UserDefaults keys directly.
///
/// S1 behaviour (this slice): the roster + active pointer are
/// maintained, but legacy storage paths still operate alongside.
/// Migration on first launch wraps the existing single-identity state
/// as `Account[0]` so an upgraded TF57 user sees zero change. S2
/// pivots the Keychain and MessageDB readers over to per-account
/// addressing; S3 surfaces the switcher in UI.
///
/// Bootstrap order:
///   1. Load persisted accounts from UserDefaults. If non-empty,
///      done — subsequent launches always take this path.
///   2. Otherwise check legacy state (`rcq.baseURL` UserDefaults +
///      `KeychainStore.Keys.uin`). If either is set, wrap that
///      identity as Account[0] with a freshly minted UUID.
///   3. Otherwise: empty roster (truly fresh install).
@MainActor
final class AccountManager: ObservableObject {
    static let shared = AccountManager()

    @Published private(set) var accounts: [Account] = []
    @Published private(set) var activeAccountID: UUID?

    /// Currently active account, or nil on a fresh install before
    /// any onboarding has run.
    var active: Account? {
        guard let id = activeAccountID else { return nil }
        return accounts.first(where: { $0.id == id })
    }

    /// Convenience for callers that need a server URL with the
    /// "empty means default" legacy convention preserved. Returns
    /// the active account's serverURL, falling back to
    /// `https://api.rcq.app` on a fresh install where no account
    /// exists yet (e.g. the very first APIClient call from
    /// OnboardingView before registration).
    var activeServerURL: String {
        active?.serverURL ?? "https://api.rcq.app"
    }

    private static let accountsKey = "rcq.accounts.v1"
    private static let activeKey = "rcq.accounts.activeID.v1"

    /// Hard cap on the local roster. Single-account is the 99% case;
    /// 2-3 accounts cover the realistic multi-identity uses (main +
    /// work + journalist persona). Beyond that we suspect either
    /// abuse or test setups, neither of which we owe a free pass.
    /// UI surfaces (AddAccountSheet, the switcher pill) refuse to
    /// add a sixth account and explain why. The limit is local-only;
    /// nothing in the server enforces it (server can't tell if two
    /// UINs share a device anyway).
    /// Hard ceiling the app supports regardless of server.
    /// `nonisolated` for the same reason as `serverMaxAccounts` below: the
    /// limit checks read it off the main actor, and a constant cannot race.
    nonisolated static let hardCap: Int = 5

    /// Operator-advertised cap from the ACTIVE server's `/server/info`
    /// (`max_accounts_per_device`). AppState writes it when it adopts new
    /// capabilities; `nonisolated(unsafe)` because the limit checks read it off
    /// the main actor and it's a plain Int that changes rarely.
    nonisolated(unsafe) static var serverMaxAccounts: Int = hardCap

    /// Effective per-device account cap. The operator can LOWER it per island,
    /// but never above the app's hard ceiling.
    static var maxAccounts: Int { max(1, min(hardCap, serverMaxAccounts)) }

    /// True when the roster is full. UI surfaces consult this before
    /// offering the 'Add' / 'New server' affordance.
    var isAtAccountLimit: Bool {
        accounts.count >= Self.maxAccounts
    }

    private init() {
        loadFromDefaults()
        if accounts.isEmpty {
            migrateLegacyIfPresent()
        }
        // Always announce the current active state to the legacy
        // mirror + App Group file at the end of init. Two code paths
        // arrive here: (a) loaded an existing roster from UserDefaults
        // (mirror probably already correct from previous run but
        // belt-and-suspenders), (b) just minted Account[0] from
        // legacy detection (mirror not written yet). Both need the
        // App Group activeAccountID file to be correct before any
        // other singleton — KeychainStore via resolve(), NSE on the
        // next push — reads it.
        mirrorActiveToLegacy()
        // S2 lazy backfill for S1-only installs upgrading to S2 with
        // a populated roster: `migrateLegacyIfPresent` short-circuits
        // when accounts is non-empty, so legacy unprefixed Keychain
        // entries (uin, token, identityPriv, etc.) stay alive. The
        // lazy-fallback in `KeychainStore.data` then leaks those
        // values into every newly-added account that probes the
        // prefixed slot and falls through. Migrate the legacy entries
        // to the OLDEST account (by createdAt) — that's the account
        // those keys originally belonged to before any second account
        // existed. The function is idempotent (no-op when legacy is
        // empty), so subsequent launches and fresh installs that came
        // through `migrateLegacyIfPresent` already do nothing here.
        if let oldest = accounts.min(by: { $0.createdAt < $1.createdAt }) {
            KeychainStore.migrateLegacyKeysToAccount(oldest.id)
            // Same migration story for the libsignal stores file.
            // Per-account isolation is critical: without it, a second
            // /auth/register overwrites local_identity in the shared
            // file and breaks v=2 decryption for the first account.
            // SignalProtocolDB.migrateLegacyIfPresent only moves the
            // legacy file when exactly one account is in the roster
            // — with two or more, the legacy file is unreliable and
            // gets left orphan; each account starts fresh and
            // SignalIdentityBootstrap re-registers libsignal material
            // per-account on first boot.
            SignalProtocolDB.migrateLegacyIfPresent(
                oldestAccountID: oldest.id,
                accountCount: accounts.count
            )
        }
    }

    /// Add a new account to the roster and set it active. Used by:
    ///   - First-launch onboarding (creates Account[0] for a new user)
    ///   - Multi-account add flow in S3 (creates Account[N] alongside
    ///     existing ones without burning anything)
    @discardableResult
    func add(serverURL: String, displayLabel: String? = nil, serverToken: String? = nil) -> Account? {
        // Defence in depth: even if a caller skips the
        // `isAtAccountLimit` check on the UI side, the manager
        // itself refuses to mint a sixth account.
        guard accounts.count < Self.maxAccounts else { return nil }
        let account = Account(serverURL: serverURL, displayLabel: displayLabel, serverToken: serverToken)
        accounts.append(account)
        activeAccountID = account.id
        save()
        mirrorActiveToLegacy()
        return account
    }

    /// Make a different existing account the active one. Singletons
    /// listening on `active` re-route on the next read; S2 will wire
    /// MessageDB / KeychainStore / APIClient to react automatically.
    func setActive(_ id: UUID) {
        guard accounts.contains(where: { $0.id == id }) else { return }
        activeAccountID = id
        save()
        mirrorActiveToLegacy()
    }

    /// Remove an account from the roster. Caller is responsible for
    /// wiping its Keychain entries + MessageDB file (S2 introduces
    /// helpers for that). If the removed account was active, falls
    /// back to the first remaining one — if no accounts remain, the
    /// app is back to a fresh-install state.
    func remove(_ id: UUID) {
        accounts.removeAll(where: { $0.id == id })
        RosterSnapshot.delete(accountID: id)
        if activeAccountID == id {
            activeAccountID = accounts.first?.id
        }
        save()
        mirrorActiveToLegacy()
    }

    /// Update server URL or display label on an existing account.
    /// No-op for unknown id.
    func update(_ id: UUID, serverURL: String? = nil, displayLabel: String? = nil) {
        guard let idx = accounts.firstIndex(where: { $0.id == id }) else { return }
        if let serverURL { accounts[idx].serverURL = serverURL }
        if let displayLabel { accounts[idx].displayLabel = displayLabel }
        save()
        if id == activeAccountID {
            mirrorActiveToLegacy()
        }
    }

    // MARK: - Persistence

    private func loadFromDefaults() {
        if let data = UserDefaults.standard.data(forKey: Self.accountsKey),
           let list = try? JSONDecoder().decode([Account].self, from: data) {
            accounts = list
        }
        if let raw = UserDefaults.standard.string(forKey: Self.activeKey),
           let id = UUID(uuidString: raw),
           accounts.contains(where: { $0.id == id }) {
            activeAccountID = id
        } else {
            activeAccountID = accounts.first?.id
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: Self.accountsKey)
        }
        if let id = activeAccountID {
            UserDefaults.standard.set(id.uuidString, forKey: Self.activeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.activeKey)
        }
        // Keep the App Group account-ids.txt mirror in sync. NSE
        // reads this file to know which local accounts exist when
        // routing a push to the right libsignal store. Active ID
        // is written separately by `mirrorActiveToLegacy`.
        AppGroup.writeAccountIDs(accounts.map { $0.id })
    }

    /// Two-way sync of the active account ID + URL with legacy
    /// readers. Two things happen on every change:
    ///
    /// 1. `rcq.baseURL` UserDefaults mirror — APIClient and
    ///    CustomServerSheet still read this. Empty / removed means
    ///    "use the prod default" per the existing convention.
    /// 2. App Group flat file — NSE reads the active account ID to
    ///    pick the right per-account Keychain prefix when
    ///    decrypting incoming pushes. KeychainStore in the main
    ///    app reads it too, via the same AppGroup helper, so both
    ///    targets resolve the same prefix at every Keychain hit.
    ///
    /// AccountManager is the only writer of either. Everything else
    /// reads.
    private func mirrorActiveToLegacy() {
        if let url = active?.serverURL {
            // Mirror the "empty means default" convention used by
            // APIClient + CustomServerSheet: don't bother storing
            // the default URL explicitly.
            if url == "https://api.rcq.app" {
                UserDefaults.standard.removeObject(forKey: "rcq.baseURL")
            } else {
                UserDefaults.standard.set(url, forKey: "rcq.baseURL")
            }
        } else {
            UserDefaults.standard.removeObject(forKey: "rcq.baseURL")
        }
        AppGroup.writeActiveAccountID(activeAccountID)
    }

    // MARK: - Legacy migration

    /// Detect a pre-v0.3 single-tenant install and wrap its state as
    /// `Account[0]`. Idempotent — runs at most once because once an
    /// account exists, `loadFromDefaults` populates `accounts` and
    /// `init()` skips this method.
    ///
    /// Detection heuristic: a legacy install has at least one of:
    ///   - `rcq.baseURL` UserDefaults set (custom server picked
    ///     via CustomServerSheet, or via the new OnboardingView
    ///     picker on a pre-v0.3 build)
    ///   - `KeychainStore.Keys.uin` populated (user already
    ///     registered)
    /// Either alone is enough — mid-onboarding states (baseURL set
    /// before register completes) and legacy default-server installs
    /// (never touched rcq.baseURL but registered) both round-trip
    /// correctly.
    ///
    /// S1 deliberately does NOT delete legacy keys here. The
    /// Keychain entries (uin, token, identityPriv, etc.) stay under
    /// their global names so APIClient + AppState + KeychainStore
    /// readers continue to find them with no code change in S1. S2
    /// rewrites those readers to use per-account prefixes and
    /// renames the legacy keys to the Account[0] prefix at the same
    /// time.
    private func migrateLegacyIfPresent() {
        let legacyServer = UserDefaults.standard.string(forKey: "rcq.baseURL") ?? ""
        // Probe the legacy unprefixed UIN slot directly. We can't use
        // the normal KeychainStore.string accessor here because it
        // resolves through AppGroup.readActiveAccountID, and at this
        // point we haven't written one yet — so it'd correctly look
        // under the (nonexistent) prefixed slot and return nil, even
        // when a legacy unprefixed UIN exists. The accessor falls
        // back to unprefixed on miss, so this works either way today,
        // but being explicit guards against future changes.
        let hasUIN = KeychainStore.string(KeychainStore.Keys.uin) != nil

        if legacyServer.isEmpty && !hasUIN {
            // Truly fresh install. Nothing to migrate.
            return
        }

        let url = legacyServer.isEmpty ? "https://api.rcq.app" : legacyServer
        let migrated = Account(serverURL: url)
        accounts = [migrated]
        activeAccountID = migrated.id
        // Move every legacy unprefixed Keychain entry under Account[0]'s
        // prefix before announcing the new active ID to the App Group —
        // that way the moment NSE / KeychainStore.resolve sees a
        // non-nil activeAccountID, the prefixed entries are already in
        // place. Migration is an explicit one-shot keyed to the new
        // account ID; it doesn't depend on App Group state.
        KeychainStore.migrateLegacyKeysToAccount(migrated.id)
        save()
    }
}
