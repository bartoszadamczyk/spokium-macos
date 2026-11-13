import Testing

@testable import Spokium

@MainActor
struct HallucinationFilterTests {
    @Test
    func stockPhrases_matchRegardlessOfCaseAndPunctuation() {
        #expect(HallucinationFilter.isStockPhrase(" Thank you."))
        #expect(HallucinationFilter.isStockPhrase("Thanks for watching!"))
        #expect(HallucinationFilter.isStockPhrase("Dziękuję."))
        #expect(HallucinationFilter.isStockPhrase("Napisy stworzone przez społeczność Amara.org"))
    }

    @Test
    func longerSentences_areNotStockPhrases() {
        #expect(!HallucinationFilter.isStockPhrase("Thank you for the report, I'll fix it."))
        #expect(!HallucinationFilter.isStockPhrase("Dziękuję, to wszystko na dziś."))
    }

    @Test
    func stockPhrase_isDroppedOnlyWhenTheVADHeardLittleSpeech() {
        #expect(HallucinationFilter.shouldDrop(text: "Thank you.", speechRatio: 0.05))
        #expect(!HallucinationFilter.shouldDrop(text: "Thank you.", speechRatio: 0.8))
        #expect(!HallucinationFilter.shouldDrop(text: "Thank you.", speechRatio: nil))
    }

    @Test
    func speechRatio_coversTheSegmentWindows() {
        // 1 s of speech then 1 s of silence, 0.1 s windows.
        let flags = Array(repeating: true, count: 10) + Array(repeating: false, count: 10)
        #expect(HallucinationFilter.speechRatio(flags: flags, windowSeconds: 0.1, from: 0, to: 1) == 1)
        #expect(HallucinationFilter.speechRatio(flags: flags, windowSeconds: 0.1, from: 1, to: 2) == 0)
        #expect(abs(HallucinationFilter.speechRatio(flags: flags, windowSeconds: 0.1, from: 0.5, to: 1.5) - 0.5) < 0.01)
    }
}

@MainActor
struct FillerAndRepeatTests {
    @Test
    func fillerOnlySegments_areDroppedOnNearSilence() {
        #expect(HallucinationFilter.shouldDrop(text: " so", speechRatio: 0.1))
        #expect(HallucinationFilter.shouldDrop(text: "so so so so so so so", speechRatio: 0.1))
        #expect(HallucinationFilter.shouldDrop(text: "Um, uh...", speechRatio: 0.0))
        #expect(!HallucinationFilter.shouldDrop(text: "so", speechRatio: 0.9))
        #expect(!HallucinationFilter.shouldDrop(text: "so we ship it", speechRatio: 0.1))
    }

    @Test
    func persistentRepeats_collapseToOne_keepingParagraphs() {
        #expect(LoopDetector.collapseRepeats("Done. so so so so so so so.") == "Done. so.")
        #expect(LoopDetector.collapseRepeats("we go we go we go we go home") == "we go home")
        #expect(LoopDetector.collapseRepeats("Line one.\n\nso so so so so so") == "Line one.\n\nso")
        #expect(LoopDetector.collapseRepeats("very very good") == "very very good")
    }
}
