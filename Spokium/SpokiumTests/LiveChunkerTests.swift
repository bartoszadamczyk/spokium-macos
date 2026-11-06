import Testing

@testable import Spokium

@MainActor
struct LiveChunkerTests {
    private let rate = 16_000

    private func speech(_ seconds: Double) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { i in 0.1 * Float(i % 2 == 0 ? 1 : -1) }
    }

    private func silence(_ seconds: Double) -> [Float] {
        Array(repeating: 0, count: Int(seconds * Double(rate)))
    }

    @Test
    func shortSpeech_emitsNothingUntilFlush() {
        var chunker = LiveChunker()
        #expect(chunker.append(speech(5)).isEmpty)
        let last = chunker.flush()
        #expect(last != nil)
        #expect(abs((last?.duration ?? 0) - 5) < 0.06)
    }

    @Test
    func silenceOnly_flushReturnsNil() {
        var chunker = LiveChunker()
        #expect(chunker.append(silence(20)).isEmpty)
        #expect(chunker.flush() == nil)
    }

    @Test
    func pauseAfterMinLength_cutsWithoutOverlap() {
        var chunker = LiveChunker()
        let chunks = chunker.append(speech(12) + silence(1) + speech(3))
        #expect(chunks.count == 1)
        #expect(chunks.first?.trailingOverlap == 0)
        let duration = chunks.first?.duration ?? 0
        #expect(duration > 12 && duration < 13)
    }

    @Test
    func pauseBeforeMinLength_doesNotCut() {
        var chunker = LiveChunker()
        #expect(chunker.append(speech(4) + silence(1) + speech(3)).isEmpty)
    }

    @Test
    func continuousSpeech_forcesCutWithOverlap() {
        var chunker = LiveChunker()
        let chunks = chunker.append(speech(40))
        #expect(chunks.count == 1)
        #expect(abs((chunks.first?.duration ?? 0) - 28) < 0.06)
        #expect(chunks.first?.trailingOverlap == 2)

        let next = chunker.flush()
        #expect(next?.leadingOverlap == 2)
        #expect(next?.pauseBefore == 0)
        // 40 s total, 28 s in the first chunk, 2 s of it repeated in the second.
        #expect(abs((next?.duration ?? 0) - 14) < 0.06)
    }

    @Test
    func shortGapNearMaxLength_isPreferredOverForcedCut() {
        var chunker = LiveChunker()
        let chunks = chunker.append(speech(24) + silence(0.3) + speech(10))
        #expect(chunks.count == 1)
        #expect(chunks.first?.trailingOverlap == 0)
        let duration = chunks.first?.duration ?? 0
        #expect(duration > 24 && duration < 24.3)
    }

    @Test
    func longPause_isReportedOnNextChunk_andLeadingSilenceIsTrimmed() {
        var chunker = LiveChunker()
        let first = chunker.append(speech(11) + silence(5) + speech(2))
        #expect(first.count == 1)
        let second = chunker.flush()
        let pause = second?.pauseBefore ?? 0
        #expect(abs(pause - 5) < 0.1)
        // Leading silence capped at 0.5 s, so the chunk is ~2.5 s, not ~4.6 s.
        #expect((second?.duration ?? 0) < 2.6)
    }

    @Test
    func incrementalAppends_matchSingleAppend() {
        var whole = LiveChunker()
        var incremental = LiveChunker()
        let audio = speech(12) + silence(1) + speech(30)

        let wholeChunks = whole.append(audio)
        var incrementalChunks: [LiveChunker.Chunk] = []
        var index = 0
        while index < audio.count {
            let end = min(audio.count, index + 1_365)
            incrementalChunks += incremental.append(Array(audio[index..<end]))
            index = end
        }
        #expect(wholeChunks == incrementalChunks)
        #expect(whole.flush() == incremental.flush())
    }
}
