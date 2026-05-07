import SwiftUI

/// In-chat message search. Same blur-backed surface as the global
/// `SearchOverlay` on the contact list, but scoped to the messages
/// of the current thread — text bubbles only, deleted-for-everyone
/// tombstones excluded. Tapping a hit closes the overlay and asks
/// the host `ChatView` to scroll to that message id.
struct InChatSearchOverlay: View {
    let messages: [Message]
    let onClose: () -> Void
    let onSelectMessage: (Message) -> Void

    @State private var query: String = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            VStack(spacing: 0) {
                searchField
                Divider().background(Theme.Color.divider.opacity(0.4))
                results
            }
            .background(.ultraThinMaterial)
            .ignoresSafeArea(edges: .bottom)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                fieldFocused = true
            }
        }
    }

    // MARK: - field

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(Theme.Color.textSecondary)
                .font(.system(size: 17))
            TextField("", text: $query, prompt: Text("chat.search.placeholder".localized)
                .foregroundColor(Theme.Color.textSecondary))
                .focused($fieldFocused)
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .regular))
                .foregroundColor(Theme.Color.textPrimary)
                .submitLabel(.search)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button {
                    query = ""
                    fieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Theme.Color.textSecondary)
                        .font(.system(size: 17))
                }
            }
            Button("search.cta.cancel".localized) { onClose() }
                .font(.system(size: 15))
                .foregroundColor(Theme.Color.accent)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    // MARK: - results

    private var normalized: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Hits across the current thread. Text bubbles only — media
    /// captions ride on `.photo` / `.video` rows whose `text` field
    /// holds the caption, so include those too. System notices and
    /// delete-for-everyone tombstones are skipped: they're not
    /// user-authored content. Sorted newest-first; capped at 100
    /// rows since a single thread shouldn't ever need more in one
    /// pass.
    private var hits: [Message] {
        let q = normalized
        guard !q.isEmpty else { return [] }
        let filtered = messages.filter { m in
            guard !m.deletedForEveryone else { return false }
            switch m.kind {
            case .text, .photo, .video: return m.text.lowercased().contains(q)
            default: return false
            }
        }
        return Array(filtered.sorted(by: { $0.sentAt > $1.sentAt }).prefix(100))
    }

    @ViewBuilder
    private var results: some View {
        if normalized.isEmpty {
            VStack(spacing: 6) {
                Spacer().frame(height: 60)
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 30))
                    .foregroundColor(Theme.Color.textSecondary)
                Text("chat.search.empty.idle".localized)
                    .font(.caption)
                    .foregroundColor(Theme.Color.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Spacer()
            }
        } else if hits.isEmpty {
            VStack(spacing: 6) {
                Spacer().frame(height: 60)
                Text("search.empty.no_match".localized)
                    .font(.caption)
                    .foregroundColor(Theme.Color.textSecondary)
                Spacer()
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(hits) { msg in
                            row(for: msg)
                        }
                    } header: {
                        sectionHeader("search.section.messages".localized)
                    }
                }
                .padding(.bottom, 30)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundColor(Theme.Color.textSecondary)
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func row(for msg: Message) -> some View {
        Button { onSelectMessage(msg) } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: rowIcon(for: msg))
                    .font(.system(size: 14))
                    .foregroundColor(Theme.Color.accent)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    EmoticonText(text: snippet(for: msg), font: .body, emoticonSize: 18)
                        .lineLimit(2)
                    Text(subtitle(for: msg))
                        .font(Theme.Font.monoSmall)
                        .foregroundColor(Theme.Color.textMono)
                }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func rowIcon(for msg: Message) -> String {
        switch msg.kind {
        case .photo: return "photo"
        case .video: return "video"
        default: return "bubble.left"
        }
    }

    /// Caption-aware snippet — for media bubbles with no caption we
    /// can't reach this row in the first place (the filter above
    /// already requires `text.contains(q)`), so showing `text`
    /// directly is fine.
    private func snippet(for msg: Message) -> String {
        switch msg.kind {
        case .photo: return msg.text.isEmpty ? "📷" : "📷 \(msg.text)"
        case .video: return msg.text.isEmpty ? "🎬" : "🎬 \(msg.text)"
        case .voice: return "🎤"
        default: return msg.text
        }
    }

    /// Subtitle is the bubble's calendar-day label — author is
    /// implicit (the user is searching inside one thread) so dropping
    /// the nickname keeps the row tight while still locating the hit
    /// on the timeline.
    private func subtitle(for msg: Message) -> String {
        DateFormatters.dayDivider.string(from: msg.sentAt)
    }
}
