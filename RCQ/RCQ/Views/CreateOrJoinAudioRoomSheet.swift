import SwiftUI

/// Sheet for creating or joining an audio room. Both paths resolve to an `AudioRoom`.
struct CreateOrJoinAudioRoomSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var rooms = AudioRoomService.shared

    var onResolved: (AudioRoom) -> Void = { _ in }

    @State private var mode: Mode = .create
    @State private var name: String = ""
    @State private var key: String = ""
    @State private var busy: Bool = false
    @State private var error: String?

    enum Mode: String, CaseIterable, Identifiable {
        case create, join
        var id: String { rawValue }
        var label: String {
            (self == .create
                ? "audio_room.sheet.mode.create"
                : "audio_room.sheet.mode.join").localized
        }
    }

    var body: some View {
        NavigationStack {
            formBody
                .navigationTitle("audio_room.sheet.title".localized)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { sheetToolbar }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // listSectionSpacing(.compact) is iOS 17+; split so iOS 16 build doesn't complain.
    @ViewBuilder
    private var formBody: some View {
        let f = formContent
        if #available(iOS 17.0, *) {
            f.listSectionSpacing(.compact)
        } else {
            f
        }
    }

    @ToolbarContentBuilder
    private var sheetToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("common.cancel".localized) { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button((mode == .create
                ? "audio_room.sheet.button.create"
                : "audio_room.sheet.button.join").localized) {
                Task { await submit() }
            }
            .disabled(busy || !canSubmit)
        }
    }

    private var formContent: some View {
        Form {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: mode == .create
                              ? "speaker.wave.2.bubble.fill"
                              : "key.fill")
                            .font(.system(size: 44))
                            .foregroundColor(Theme.Color.accent)
                            .frame(maxWidth: .infinity)
                            .id("hero-icon-\(mode.rawValue)")
                            .transition(.opacity.combined(with: .scale(scale: 0.85)))
                        Text((mode == .create
                              ? "audio_room.sheet.hero.create"
                              : "audio_room.sheet.hero.join").localized)
                            .font(.callout)
                            .foregroundColor(Theme.Color.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                            .id("hero-text-\(mode.rawValue)")
                            .transition(.opacity)
                    }
                    .padding(.top, 0)
                    .padding(.bottom, 4)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                }

                Section {
                    Picker("", selection: $mode.animation(.easeInOut(duration: 0.22))) {
                        ForEach(Mode.allCases) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }

                // Distinct .id per mode so SwiftUI treats them as different rows and animates the swap.
                Group {
                    if mode == .create {
                        Section {
                            TextField("audio_room.sheet.field.name".localized, text: $name)
                                .textInputAutocapitalization(.words)
                        } footer: {
                            Text("audio_room.sheet.footer.create".localized)
                                .font(.footnote)
                        }
                        .id("field-create")
                        .transition(.opacity)
                    } else {
                        Section {
                            TextField("audio_room.sheet.field.key".localized, text: $key)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                        } footer: {
                            Text("audio_room.sheet.footer.join".localized)
                                .font(.footnote)
                        }
                        .id("field-join")
                        .transition(.opacity)
                    }
                }

                if let error {
                    Section {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.footnote)
                    }
                }
        }
    }

    private var canSubmit: Bool {
        switch mode {
        case .create: return !name.trimmingCharacters(in: .whitespaces).isEmpty
        case .join:   return key.trimmingCharacters(in: .whitespaces).count >= 4
        }
    }

    private func submit() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            let room: AudioRoom
            switch mode {
            case .create:
                room = try await rooms.create(name: name.trimmingCharacters(in: .whitespaces))
            case .join:
                room = try await rooms.join(byKey: key.trimmingCharacters(in: .whitespaces))
            }
            onResolved(room)
            dismiss()
        } catch {
            self.error = (mode == .create
                ? "audio_room.sheet.error.create"
                : "audio_room.sheet.error.join").localized
        }
    }
}
