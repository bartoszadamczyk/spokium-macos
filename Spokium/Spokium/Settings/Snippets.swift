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
    private static let key = "snippets"

    static func load() -> [Snippet] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let snippets = try? JSONDecoder().decode([Snippet].self, from: data) else {
            return []
        }
        return snippets
    }

    static func save(_ snippets: [Snippet]) {
        guard let data = try? JSONEncoder().encode(snippets) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func apply(to text: String) -> String {
        let snippets = load().filter { !$0.trigger.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !snippets.isEmpty else { return text }

        var result = text
        for snippet in snippets {
            let trigger = snippet.trigger.trimmingCharacters(in: .whitespaces)
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: trigger) + "\\b"
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
