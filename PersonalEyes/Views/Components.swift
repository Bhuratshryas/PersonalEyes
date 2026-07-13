import SwiftUI
import UIKit

extension Color {
    /// Adaptive monochrome accent: graphite black on light backgrounds, soft
    /// white on dark backgrounds. Mirrors the look of the app icon — a single
    /// dark glyph on a near-white surface.
    static let personalEyesAccent = Color.primary
}

struct PreferenceToggle: View {
    var title: String
    var subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .tint(Color.personalEyesAccent)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityHint(subtitle)
    }
}

struct CustomPromptsEditor: View {
    @ObservedObject var store: PromptStore

    @State private var draftQuestion: String = ""
    @FocusState private var isDraftFocused: Bool

    var body: some View {
        Section {
            ForEach(store.prompts) { prompt in
                CustomPromptRow(prompt: prompt, store: store)
            }
            .onDelete { offsets in
                store.remove(at: offsets)
                UIAccessibility.post(notification: .announcement, argument: "Question removed.")
            }

            HStack(spacing: 10) {
                Image(systemName: "questionmark.bubble")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                TextField("Add a question, like \"Is it organic?\"", text: $draftQuestion, axis: .vertical)
                    .textInputAutocapitalization(.sentences)
                    .submitLabel(.done)
                    .focused($isDraftFocused)
                    .onSubmit { addDraft() }
                    .accessibilityLabel("New question")
                    .accessibilityHint("Type a question, then tap Add")

                Button {
                    addDraft()
                } label: {
                    Text("Add")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.personalEyesAccent)
                .foregroundStyle(Color(.systemBackground))
                .controlSize(.regular)
                .disabled(draftQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Add question")
                .accessibilityHint("Saves the typed question to your custom prompts")
            }
        } header: {
            Text("Custom Questions")
        } footer: {
                    Text("Extra questions are answered after the image description when Apple Intelligence is available. Swipe a row to delete.")
        }
    }

    private func addDraft() {
        let trimmed = draftQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if store.add(trimmed) != nil {
            draftQuestion = ""
            isDraftFocused = false
            UIAccessibility.post(notification: .announcement, argument: "Question added.")
        } else {
            UIAccessibility.post(notification: .announcement, argument: "That question is already in your list.")
        }
    }
}

private struct CustomPromptRow: View {
    let prompt: CustomPrompt
    @ObservedObject var store: PromptStore

    @State private var draft: String

    init(prompt: CustomPrompt, store: PromptStore) {
        self.prompt = prompt
        self.store = store
        self._draft = State(initialValue: prompt.question)
    }

    var body: some View {
        Toggle(isOn: enabledBinding) {
            TextField("Question", text: $draft, axis: .vertical)
                .textInputAutocapitalization(.sentences)
                .onSubmit {
                    store.update(prompt, question: draft)
                }
                .onChange(of: draft) { _, newValue in
                    if newValue != prompt.question {
                        store.update(prompt, question: newValue, debounce: true)
                    }
                }
                .accessibilityLabel("Question text")
        }
        .tint(Color.personalEyesAccent)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(draft.isEmpty ? prompt.question : draft), \(prompt.isEnabled ? "enabled" : "disabled")")
        .accessibilityHint("Double-tap to toggle. Swipe to delete.")
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { prompt.isEnabled },
            set: { newValue in
                store.setEnabled(prompt, isEnabled: newValue)
            }
        )
    }
}
