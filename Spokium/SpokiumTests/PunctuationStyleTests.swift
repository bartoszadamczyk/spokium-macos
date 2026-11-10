import Foundation
import Testing

@testable import Spokium

@MainActor
struct PunctuationStyleTests {
    private let flat = "so i was thinking we could move the meeting to thursday and then maybe grab lunch after if that works for everyone"

    @Test
    func longLowercaseWithoutPunctuation_isFlagged() {
        #expect(PunctuationStyle.isUnpunctuated(flat))
    }

    @Test
    func anyPunctuationOrCapital_isNotFlagged() {
        #expect(!PunctuationStyle.isUnpunctuated(flat + "."))
        #expect(!PunctuationStyle.isUnpunctuated("So" + flat.dropFirst(2)))
        #expect(!PunctuationStyle.isUnpunctuated(flat.replacingOccurrences(of: " and ", with: ", and ")))
    }

    @Test
    func shortPhrase_isNotFlagged() {
        #expect(!PunctuationStyle.isUnpunctuated("ok sounds good to me"))
    }

    @Test
    func polishFlatText_isFlagged() {
        let pl = "no więc myślałem że moglibyśmy przenieść spotkanie na czwartek a potem pójść razem na obiad jeśli wszystkim pasuje"
        #expect(PunctuationStyle.isUnpunctuated(pl))
    }

    @Test
    func uncasedScripts_areNeverFlagged() {
        let ja = String(repeating: "今日は 会議が あります ", count: 8)
        #expect(!PunctuationStyle.isUnpunctuated(ja, minWords: 5))
    }

    @Test
    func retryPrompt_endsWithExampleSentence_keepsDictionary() {
        let prompt = PunctuationStyle.retryPrompt(original: "Spokium, whisper.cpp", language: "pl")
        #expect(prompt?.hasPrefix("Spokium, whisper.cpp ") == true)
        #expect(prompt?.hasSuffix("interpunkcją.") == true)
        #expect(PunctuationStyle.retryPrompt(original: nil, language: "en") == PunctuationStyle.exampleSentence(for: "en"))
    }

    @Test
    func languageWithoutSentence_skipsRetry() {
        #expect(PunctuationStyle.retryPrompt(original: "x", language: "cs") == nil)
    }
}
