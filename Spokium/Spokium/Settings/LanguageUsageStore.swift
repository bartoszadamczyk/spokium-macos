import Foundation

// Characters transcribed per detected language, across all sessions. Stores only
// counts per language code — never text. Used as the long-term fallback language
// and shown as "your usage" in Settings → Transcription.
enum LanguageUsageStore {
    static func record(language: String, characters: Int) {
        let updated = merge(into: load(), language: language, characters: characters)
        save(updated)
    }

    static func all() -> [String: Int] {
        load()
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: DefaultsKey.languageUsage)
    }

    // Pure aggregation, exposed for tests. Ignores empty text and unknown languages.
    nonisolated static func merge(into counts: [String: Int], language: String, characters: Int) -> [String: Int] {
        guard characters > 0, !language.isEmpty, language != "unknown" else { return counts }
        var counts = counts
        counts[language, default: 0] += characters
        return counts
    }

    // Languages sorted by share of total characters, largest first.
    nonisolated static func shares(_ counts: [String: Int]) -> [(code: String, fraction: Double)] {
        let total = counts.values.reduce(0, +)
        guard total > 0 else { return [] }
        return counts
            .filter { $0.value > 0 }
            .map { (code: $0.key, fraction: Double($0.value) / Double(total)) }
            .sorted { $0.fraction > $1.fraction || ($0.fraction == $1.fraction && $0.code < $1.code) }
    }

    private static func load() -> [String: Int] {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.languageUsage),
              let dict = try? JSONDecoder().decode([String: Int].self, from: data)
        else { return [:] }
        return dict
    }

    private static func save(_ dict: [String: Int]) {
        guard let data = try? JSONEncoder().encode(dict) else { return }
        UserDefaults.standard.set(data, forKey: DefaultsKey.languageUsage)
    }
}
