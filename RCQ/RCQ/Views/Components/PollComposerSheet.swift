import SwiftUI

/// Compose a new group poll. Owner enters a question + 2–10 options
/// + a couple of flags; `onSubmit` ships the final tuple back to
/// `ChatView`, which creates the server-side poll then broadcasts
/// the `.poll` envelope to the group's members.
struct PollComposerSheet: View {
    let onSubmit: (PollDraft) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var question: String = ""
    @State private var options: [String] = ["", ""]
    @State private var singleChoice: Bool = true
    @State private var anonymous: Bool = false
    @State private var submitting: Bool = false

    private static let minOptions: Int = 2
    private static let maxOptions: Int = 10
    private static let maxQuestionLen: Int = 240
    private static let maxOptionLen: Int = 100

    struct PollDraft {
        let question: String
        let options: [String]
        let singleChoice: Bool
        let anonymous: Bool
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("poll.compose.question_placeholder".localized, text: $question, axis: .vertical)
                        .lineLimit(2...4)
                        .onChange(of: question) { _ in
                            if question.count > Self.maxQuestionLen {
                                question = String(question.prefix(Self.maxQuestionLen))
                            }
                        }
                } header: {
                    Text("poll.compose.question_header".localized)
                }

                Section {
                    ForEach(options.indices, id: \.self) { idx in
                        HStack(spacing: 8) {
                            TextField(
                                String(format: "poll.compose.option_placeholder".localized, idx + 1),
                                text: Binding(
                                    get: { options[idx] },
                                    set: { newValue in
                                        options[idx] = String(newValue.prefix(Self.maxOptionLen))
                                    }
                                )
                            )
                            if options.count > Self.minOptions {
                                Button(role: .destructive) {
                                    options.remove(at: idx)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundColor(.red.opacity(0.7))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if options.count < Self.maxOptions {
                        Button {
                            options.append("")
                        } label: {
                            Label("poll.compose.add_option".localized, systemImage: "plus.circle")
                                .foregroundColor(Theme.Color.accent)
                        }
                    }
                } header: {
                    Text("poll.compose.options_header".localized)
                }

                Section {
                    Toggle("poll.compose.multi".localized, isOn: Binding(
                        get: { !singleChoice },
                        set: { singleChoice = !$0 }
                    ))
                    Toggle("poll.compose.anonymous".localized, isOn: $anonymous)
                } footer: {
                    Text("poll.compose.flags_footer".localized)
                        .font(.caption2)
                }
            }
            .navigationTitle("poll.compose.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel".localized) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        guard canSubmit else { return }
                        submitting = true
                        let cleanedOptions = options
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        onSubmit(PollDraft(
                            question: question.trimmingCharacters(in: .whitespacesAndNewlines),
                            options: cleanedOptions,
                            singleChoice: singleChoice,
                            anonymous: anonymous
                        ))
                        dismiss()
                    } label: {
                        if submitting {
                            ProgressView()
                        } else {
                            Text("poll.compose.send".localized)
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(!canSubmit || submitting)
                }
            }
        }
    }

    private var canSubmit: Bool {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return false }
        let validOptions = options
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return validOptions.count >= Self.minOptions
    }
}
