import Foundation

struct CustomPrompt: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var question: String
    var isEnabled: Bool

    init(id: UUID = UUID(), question: String, isEnabled: Bool = true) {
        self.id = id
        self.question = question
        self.isEnabled = isEnabled
    }
}

@MainActor
final class PromptStore: ObservableObject {
    @Published private(set) var prompts: [CustomPrompt] = []

    private let storageKey = "PersonalEyes.customPrompts.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    var enabledQuestions: [String] {
        prompts
            .filter(\.isEnabled)
            .map { $0.question.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    @discardableResult
    func add(_ question: String) -> CustomPrompt? {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !prompts.contains(where: { $0.question.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            return nil
        }
        let prompt = CustomPrompt(question: trimmed)
        prompts.append(prompt)
        persist()
        return prompt
    }

    func update(_ prompt: CustomPrompt, question: String) {
        guard let index = prompts.firstIndex(where: { $0.id == prompt.id }) else { return }
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        prompts[index].question = trimmed
        persist()
    }

    func setEnabled(_ prompt: CustomPrompt, isEnabled: Bool) {
        guard let index = prompts.firstIndex(where: { $0.id == prompt.id }) else { return }
        prompts[index].isEnabled = isEnabled
        persist()
    }

    func remove(at offsets: IndexSet) {
        prompts.remove(atOffsets: offsets)
        persist()
    }

    private func load() {
        guard
            let data = defaults.data(forKey: storageKey),
            let decoded = try? JSONDecoder().decode([CustomPrompt].self, from: data)
        else {
            prompts = []
            return
        }
        prompts = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(prompts) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
