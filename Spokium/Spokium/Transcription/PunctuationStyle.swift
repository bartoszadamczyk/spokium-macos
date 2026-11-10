import Foundation

// Whisper sometimes slips into a flat style: everything lowercase, no punctuation. It
// copies the style of its prompt, so a lowercase word list or an already-flat previous
// chunk (live mode) can trigger it and keep it going. The fix is to detect the flat
// output and re-run once with a properly punctuated sentence as the latest prompt text.
nonisolated enum PunctuationStyle {
    private static let punctuation = CharacterSet(charactersIn: ".,!?;:…¿¡")

    // Long enough to expect at least one mark, no punctuation, and no capital letters.
    // Scripts without letter case (Chinese, Japanese, Thai…) are never flagged.
    static func isUnpunctuated(_ text: String, minWords: Int = 15) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count >= minWords else { return false }
        guard text.unicodeScalars.allSatisfy({ !punctuation.contains($0) }) else { return false }
        let cased = text.filter { $0.isLetter && $0.isCased }
        guard cased.count >= 20 else { return false }
        return !cased.contains { $0.isUppercase }
    }

    // A short, well-punctuated sentence in the transcript's language, used as the most
    // recent prompt text. nil for languages without one: an English sentence could pull
    // the decoder towards English (and translation) for other languages.
    static func exampleSentence(for language: String) -> String? {
        switch language {
        case "en": "Hello, everyone. Here is the transcript, with proper punctuation."
        case "pl": "Dzień dobry. Oto transkrypcja, z poprawną interpunkcją."
        case "de": "Guten Tag. Hier ist das Transkript, mit korrekter Zeichensetzung."
        case "fr": "Bonjour. Voici la transcription, avec une ponctuation correcte."
        case "es": "Hola. Aquí está la transcripción, con la puntuación correcta."
        case "it": "Buongiorno. Ecco la trascrizione, con la punteggiatura corretta."
        case "pt": "Olá. Aqui está a transcrição, com a pontuação correta."
        case "nl": "Goedendag. Hier is het transcript, met de juiste interpunctie."
        default: nil
        }
    }

    // Keeps the existing prompt (dictionary terms) but makes the example sentence the
    // last thing whisper reads, since the end of the prompt shapes the style most.
    static func retryPrompt(original: String?, language: String) -> String? {
        guard let sentence = exampleSentence(for: language) else { return nil }
        guard let original, !original.isEmpty else { return sentence }
        return original + " " + sentence
    }
}

nonisolated private extension Character {
    var isCased: Bool { isUppercase || isLowercase }
}
