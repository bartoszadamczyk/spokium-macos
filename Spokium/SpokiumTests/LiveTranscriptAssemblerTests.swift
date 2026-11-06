import Testing

@testable import Spokium

@MainActor
struct LiveTranscriptAssemblerTests {
    private func info(
        duration: Double = 10,
        leading: Double = 0,
        trailing: Double = 0,
        pause: Double = 0
    ) -> LiveTranscriptAssembler.ChunkInfo {
        .init(duration: duration, leadingOverlap: leading, trailingOverlap: trailing, pauseBefore: pause)
    }

    private func words(_ pairs: [(String, Double)]) -> [TimedWord] {
        pairs.map { TimedWord(text: $0.0, start: $0.1) }
    }

    @Test
    func pauseSeams_joinWithSpace_orParagraph() {
        var assembler = LiveTranscriptAssembler(paragraphSplitting: true, paragraphPauseSeconds: 3)
        assembler.append(text: " First part.", words: [], info: info())
        assembler.append(text: " Second part.", words: [], info: info(pause: 1))
        assembler.append(text: " New topic.", words: [], info: info(pause: 4))
        #expect(assembler.text == "First part. Second part.\n\nNew topic.")
    }

    @Test
    func paragraphSplittingOff_alwaysUsesSpace() {
        var assembler = LiveTranscriptAssembler(paragraphSplitting: false, paragraphPauseSeconds: 3)
        assembler.append(text: "One.", words: [], info: info())
        assembler.append(text: "Two.", words: [], info: info(pause: 10))
        #expect(assembler.text == "One. Two.")
    }

    @Test
    func overlapSeam_dropsDuplicatedWords_andFixesCasing() {
        var assembler = LiveTranscriptAssembler(paragraphSplitting: true, paragraphPauseSeconds: 3)
        // Chunk A: 28 s, last 2 s overlap. Midpoint at 27 s.
        assembler.append(
            text: " We walked to the old market.",
            words: words([(" We", 20), (" walked", 21), (" to", 25.5), (" the", 26.5), (" old", 27.2), (" market.", 27.6)]),
            info: info(duration: 28, trailing: 2)
        )
        // Chunk B starts 2 s before A ended. Midpoint at 1 s.
        assembler.append(
            text: " The old market was busy.",
            words: words([(" The", 0.3), (" Old", 1.2), (" market", 1.6), (" was", 2.4), (" busy.", 2.8)]),
            info: info(duration: 10, leading: 2)
        )
        #expect(assembler.text == "We walked to the old market was busy.")
    }

    @Test
    func overlapSeam_afterSentenceEnd_keepsCapital() {
        var assembler = LiveTranscriptAssembler(paragraphSplitting: true, paragraphPauseSeconds: 3)
        assembler.append(text: " Done.", words: words([(" Done.", 1)]), info: info(duration: 28, trailing: 2))
        assembler.append(text: " Next one.", words: words([(" Next", 1.5), (" one.", 2)]), info: info(leading: 2))
        #expect(assembler.text == "Done. Next one.")
    }

    @Test
    func overlapSeam_keepsAcronymsAndI() {
        var assembler = LiveTranscriptAssembler(paragraphSplitting: true, paragraphPauseSeconds: 3)
        assembler.append(text: " so", words: words([(" so", 1)]), info: info(duration: 28, trailing: 2))
        assembler.append(text: " NASA said", words: words([(" NASA", 1.5), (" said", 2)]), info: info(duration: 28, leading: 2, trailing: 2))
        assembler.append(text: " I think", words: words([(" I", 1.5), (" think", 2)]), info: info(leading: 2))
        #expect(assembler.text == "so NASA said I think")
    }

    @Test
    func overlapWithoutWords_fallsBackToText() {
        var assembler = LiveTranscriptAssembler(paragraphSplitting: true, paragraphPauseSeconds: 3)
        assembler.append(text: "Hello there", words: [], info: info(duration: 28, trailing: 2))
        #expect(assembler.text == "Hello there")
    }

    @Test
    func emptyChunks_areSkipped() {
        var assembler = LiveTranscriptAssembler(paragraphSplitting: true, paragraphPauseSeconds: 3)
        assembler.append(text: "  ", words: [], info: info())
        assembler.append(text: "Hi.", words: [], info: info(pause: 5))
        #expect(assembler.text == "Hi.")
    }

    @Test
    func tail_cutsAtWordBoundary() {
        var assembler = LiveTranscriptAssembler(paragraphSplitting: false, paragraphPauseSeconds: 3)
        assembler.append(text: "alpha beta gamma delta", words: [], info: info())
        #expect(assembler.tail(maxCharacters: 12) == "gamma delta")
        #expect(assembler.tail(maxCharacters: 11) == "gamma delta")
        #expect(assembler.tail(maxCharacters: 9) == "delta")
        #expect(assembler.tail(maxCharacters: 100) == "alpha beta gamma delta")
    }
}
