import SwiftUI

/// Global (cross-account) store for the user's customised emoji sets, mirroring
/// the Android `LocalStores` panel/reaction prefs:
///  - `panel`: the emoticons shown in the composer smiley panel. EMPTY by
///    default → the panel shows a "Choose" CTA until the user picks a set.
///  - `reactions`: the quick reactions on the long-press reaction row (≤6).
///    Defaults to the historical six until customised.
///
/// Persisted as plain UserDefaults `[String]` arrays of asset names, like
/// `EmoticonUsageStore`. Not per-account (one set across identities), matching
/// the Android global store.
@MainActor
final class EmoticonPrefsStore: ObservableObject {
    static let shared = EmoticonPrefsStore()

    /// Default reactions until the user customises their set. Asset names match
    /// Android `Emoticons.defaultReactions` so a reaction renders identically.
    static let defaultReactions = ["good", "give_heart", "laugh1", "scare", "cray", "ireful1"]
    static let panelCap = 40
    static let reactionCap = 6

    private static let panelKey = "rcq.panel_emojis"
    private static let reactionKey = "rcq.reaction_emojis"

    @Published private(set) var panel: [String]
    @Published private(set) var reactions: [String]

    private init() {
        self.panel = (UserDefaults.standard.array(forKey: Self.panelKey) as? [String]) ?? []
        // Absent key → the default six. An empty stored array → the user
        // deliberately cleared them (respected).
        self.reactions = (UserDefaults.standard.array(forKey: Self.reactionKey) as? [String]) ?? Self.defaultReactions
    }

    /// Toggle [asset] in the panel set, respecting the cap (an add past the cap
    /// is a no-op). Order = pick order.
    func togglePanel(_ asset: String) {
        if let i = panel.firstIndex(of: asset) {
            panel.remove(at: i)
        } else if panel.count < Self.panelCap {
            panel.append(asset)
        }
        UserDefaults.standard.set(panel, forKey: Self.panelKey)
    }

    /// Toggle [asset] in the reaction set, respecting the cap of 6.
    func toggleReaction(_ asset: String) {
        if let i = reactions.firstIndex(of: asset) {
            reactions.remove(at: i)
        } else if reactions.count < Self.reactionCap {
            reactions.append(asset)
        }
        UserDefaults.standard.set(reactions, forKey: Self.reactionKey)
    }
}

/// One sheet where the user curates BOTH their composer-panel emoticons and
/// their quick reactions in a single place (founder spec), mirroring the
/// Android `EmojiPickerDialog`. A segmented control switches which set the taps
/// edit; the grid offers the whole bundled set (`Emoticons.fullSet`) with a
/// tint + checkmark on the assets already chosen. Caps: panel 40, reactions 6
/// (an add past the cap is a no-op).
struct EmoticonPickerSheet: View {
    @ObservedObject private var prefs = EmoticonPrefsStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0 // 0 = panel, 1 = reactions

    private let cols = [GridItem](repeating: GridItem(.flexible(), spacing: 8), count: 6)

    private var activeSet: Set<String> {
        Set(tab == 0 ? prefs.panel : prefs.reactions)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                Picker("", selection: $tab) {
                    Text("Panel \(prefs.panel.count)/\(EmoticonPrefsStore.panelCap)").tag(0)
                    Text("Reactions \(prefs.reactions.count)/\(EmoticonPrefsStore.reactionCap)").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Text(tab == 0
                     ? "Tap to add emoticons to your composer panel (up to 40)."
                     : "Tap to choose your quick reactions (up to 6).")
                    .font(.caption)
                    .foregroundColor(Theme.Color.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)

                ScrollView {
                    LazyVGrid(columns: cols, spacing: 8) {
                        ForEach(Emoticons.fullSet, id: \.self) { asset in
                            let selected = activeSet.contains(asset)
                            Button {
                                if tab == 0 { prefs.togglePanel(asset) } else { prefs.toggleReaction(asset) }
                            } label: {
                                // Selection is shown by the green background tint
                                // alone — no check badge (the tint reads as chosen).
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(selected ? Theme.Color.accent.opacity(0.30) : Color.clear)
                                        .frame(width: 46, height: 46)
                                    GIFImage(name: asset)
                                        .frame(width: 30, height: 30)
                                        .frame(width: 46, height: 46)
                                }
                            }
                        }
                    }
                    .padding(12)
                }
            }
            .background(Theme.Color.bgPrimary.ignoresSafeArea())
            .navigationTitle("Your emoticons")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // Slide-up drawer (not a full window): a tall bottom sheet with a grab
        // handle, draggable down to dismiss.
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}
