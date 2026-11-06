import Testing

@testable import Spokium

@MainActor
struct NoSpeechFilterTests {
    @Test
    func lowNoSpeechProb_isKept() {
        #expect(NoSpeechFilter.shouldDrop(noSpeechProb: 0.2, averageLogProb: -3.0) == false)
    }

    @Test
    func highNoSpeechProb_butConfidentText_isKept() {
        // The cut-off-last-sentence case: mostly-silent window, confidently decoded words.
        #expect(NoSpeechFilter.shouldDrop(noSpeechProb: 0.8, averageLogProb: -0.3) == false)
    }

    @Test
    func highNoSpeechProb_andUnsureText_isDropped() {
        #expect(NoSpeechFilter.shouldDrop(noSpeechProb: 0.8, averageLogProb: -1.6) == true)
    }

    @Test
    func highNoSpeechProb_withoutTokens_isDropped() {
        #expect(NoSpeechFilter.shouldDrop(noSpeechProb: 0.9, averageLogProb: nil) == true)
    }
}
