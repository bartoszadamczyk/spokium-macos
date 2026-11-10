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
            // Never saved: seed examples. Once the user edits the list (even to empty)
            // the key exists and these don't come back.
            return defaultSnippets
        }
        return snippets
    }

    static var defaultSnippets: [Snippet] {
        [
            Snippet(trigger: "new paragraph", replacement: "\\n\\n"),
            Snippet(trigger: "new line", replacement: "\\n"),
        ]
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
            // The Replacement field is single-line, so "\n" is how a line break is typed.
            let replacement = snippet.replacement.replacingOccurrences(of: "\\n", with: "\n")
            let isLineBreak = replacement.contains("\n") && replacement.allSatisfy(\.isWhitespace)
            var pattern = "(?:^|(?<=\\W))" + escaped + "(?:$|(?=\\W))"
            if isLineBreak {
                // Whisper punctuates a spoken command like a phrase ("…end, new line, next" or
                // "…end. New paragraph. Next"): drop the comma before it and the punctuation
                // and spaces after it. A sentence-ending mark before it stays.
                pattern = "(?:[ \\t]*[,;:])?[ \\t]*" + pattern + "[ \\t]*[.,;:!?]?[ \\t]*"
            }
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            result = isLineBreak
                ? replaceLineBreaks(regex, with: replacement, in: result)
                : regex.stringByReplacingMatches(
                    in: result,
                    options: [],
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
                )
        }
        return result
    }

    // Like stringByReplacingMatches, but capitalises the first letter after the break:
    // whisper continues the sentence in lower case ("New line, eggs").
    nonisolated private static func replaceLineBreaks(_ regex: NSRegularExpression, with replacement: String, in text: String) -> String {
        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            var after = String(result[range.upperBound...])
            if let first = after.first, first.isLowercase {
                after = first.uppercased() + after.dropFirst()
            }
            result = result[..<range.lowerBound] + replacement + after
        }
        return result
    }
}
