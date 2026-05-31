import Foundation

struct Snippet: Identifiable, Codable, Equatable {
    var id: UUID
    var trigger: String
    var replacement: String

    init(id: UUID = UUID(), trigger: String = "", replacement: String = "") {
        self.id = id
        self.trigger = trigger
        self.replacement = replacement
    }
}

enum SnippetStore {
    static func load() -> [Snippet] {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.snippets),
              let snippets = try? JSONDecoder().decode([Snippet].self, from: data) else {
            return []
        }
        return snippets
    }

    static func save(_ snippets: [Snippet]) {
        guard let data = try? JSONEncoder().encode(snippets) else { return }
        UserDefaults.standard.set(data, forKey: DefaultsKey.snippets)
    }

    static func apply(to text: String) -> String {
        apply(load(), to: text)
    }

    // Pure overload: same logic without touching UserDefaults, for testing and reuse.
    nonisolated static func apply(_ snippets: [Snippet], to text: String) -> String {
        let active = snippets.filter { !$0.trigger.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !active.isEmpty else { return text }

        var result = text
        for snippet in active {
            let trigger = snippet.trigger.trimmingCharacters(in: .whitespaces)
            // Use Unicode-aware lookarounds instead of `\b`, so triggers that
            // start or end with a non-word character (C++, Mr., #hello, etc.)
            // still match when surrounded by whitespace or string boundaries.
            // \W in NSRegularExpression is Unicode-aware by default, so accented
            // and CJK characters are treated as word chars correctly.
            let escaped = NSRegularExpression.escapedPattern(for: trigger)
            let pattern = "(?:^|(?<=\\W))" + escaped + "(?:$|(?=\\W))"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: snippet.replacement)
            )
        }
        return result
    }
}
