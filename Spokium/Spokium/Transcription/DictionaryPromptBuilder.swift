import Foundation

enum DictionaryPromptBuilder {
    // Turns the raw newline-separated dictionary entries into whisper's
    // `initial_prompt` format (a single comma-separated string), or nil if
    // there are no non-blank entries.
    nonisolated static func prompt(from raw: String) -> String? {
        let entries = raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !entries.isEmpty else { return nil }
        return entries.joined(separator: ", ")
    }
}
