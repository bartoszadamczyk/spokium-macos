import Foundation

// Picks the most likely language from the user's allowed set, given whisper's
// per-language probabilities. Ties go to the earlier entry in `allowed`, so the
// user's ordering acts as a preference.
nonisolated enum LanguageChooser {
    static func best(probabilities: [String: Float], allowed: [String]) -> String? {
        var best: (code: String, prob: Float)?
        for code in allowed {
            guard let prob = probabilities[code] else { continue }
            if prob > (best?.prob ?? -1) { best = (code, prob) }
        }
        return best?.code
    }

    // The language with the most accepted text so far, restricted to `allowed`.
    static func dominant(charactersByLanguage: [String: Int], allowed: [String]) -> String? {
        allowed
            .compactMap { code in charactersByLanguage[code].map { (code, $0) } }
            .filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }?
            .0
    }
}
