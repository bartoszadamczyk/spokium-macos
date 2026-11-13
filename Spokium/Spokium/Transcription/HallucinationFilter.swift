import Foundation

// Whisper was trained largely on subtitled video, so on near-silent audio (a breath, room
// noise after the last sentence) it likes to emit the stock endings of that material:
// "Thank you.", "Thanks for watching!", "Dziękuję.", subtitle credits. A segment is
// dropped only when it is *exactly* such a phrase and Silero heard almost no speech in
// its time range — a "thank you" the user actually says scores as speech and stays.
nonisolated enum HallucinationFilter {
    static let maxSpeechRatio = 0.3

    private static let phrases: Set<String> = [
        // English
        "thank you", "thank you very much", "thanks", "thank you so much",
        "thanks for watching", "thank you for watching", "thanks for listening",
        "thank you for listening", "please subscribe", "bye", "you",
        "subtitles by the amaraorg community",
        // Polish
        "dziękuję", "dziękuję bardzo", "dzięki", "dziękuję za uwagę",
        "dziękuję za obejrzenie", "do zobaczenia", "napisy stworzone przez społeczność amaraorg",
        // German, French, Spanish
        "danke", "vielen dank", "untertitel der amaraorg community",
        "merci", "merci beaucoup", "gracias", "muchas gracias",
    ]

    // Fillers whisper emits on near-silence (often repeated: "so so so so"). A segment
    // made only of these is treated like a stock phrase.
    private static let fillers: Set<String> = [
        "so", "um", "uh", "umm", "uhm", "hmm", "hm", "mm", "mhm", "ah", "oh", "eh", "er", "erm",
        "yyy", "eee", "mmm",
    ]

    static func isFillerOnly(_ text: String) -> Bool {
        let words = normalize(text).split(separator: " ")
        return !words.isEmpty && words.allSatisfy { fillers.contains(String($0)) }
    }

    static func normalize(_ text: String) -> String {
        let kept = text.lowercased().unicodeScalars.filter {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) || $0 == " "
        }
        return String(String.UnicodeScalarView(kept))
            .split(separator: " ")
            .joined(separator: " ")
    }

    static func isStockPhrase(_ text: String) -> Bool {
        phrases.contains(normalize(text))
    }

    // `speechRatio` is the share of the segment's VAD windows classified as speech; nil
    // when no VAD ran, in which case nothing is dropped.
    static func shouldDrop(text: String, speechRatio: Double?) -> Bool {
        guard let speechRatio, speechRatio < maxSpeechRatio else { return false }
        return isStockPhrase(text) || isFillerOnly(text)
    }

    // Share of 32 ms VAD windows marked speech between t0 and t1 (seconds).
    static func speechRatio(flags: [Bool], windowSeconds: Double, from t0: Double, to t1: Double) -> Double {
        let start = max(0, Int(t0 / windowSeconds))
        let end = min(flags.count, Int((t1 / windowSeconds).rounded(.up)))
        guard end > start else { return 0 }
        return Double(flags[start..<end].filter { $0 }.count) / Double(end - start)
    }
}
