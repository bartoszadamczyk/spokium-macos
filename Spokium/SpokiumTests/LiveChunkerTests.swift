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

    // Treats windows whose first sample is non-zero as speech, so tests can script
    // exactly what the "VAD" sees.
    private struct ScriptedClassifier: SpeechClassifier {
        let windowSamples = 512
        func classify(_ samples: ArraySlice<Float>) -> [Bool] {
            stride(from: samples.startIndex, to: samples.endIndex, by: windowSamples).map { samples[$0] != 0 }
        }
        func reset() {}
    }

    private func minSpeechChunker() -> LiveChunker {
        var config = LiveChunker.Config()
        config.minSpeechSeconds = 0.25
        return LiveChunker(config: config, classifier: ScriptedClassifier())
    }

    @Test
    func inaudibleBlipBelowMinSpeech_isDropped() {
        var chunker = minSpeechChunker()
        let blip = speech(0.1).map { $0 * 0.01 }
        #expect(chunker.append(silence(3) + blip + silence(3)).isEmpty)
        #expect(chunker.flush() == nil)
    }

    // A VAD that never hears speech — what Silero does with real whispering.
    private struct DeafClassifier: SpeechClassifier {
        let windowSamples = 512
        func classify(_ samples: ArraySlice<Float>) -> [Bool] {
            Array(repeating: false, count: samples.count / windowSamples)
        }
        func reset() {}
    }

    @Test
    func audibleAudio_isKept_evenWhenTheVADHearsNoSpeech() {
        var config = LiveChunker.Config()
        config.minSpeechSeconds = 0.25
        var chunker = LiveChunker(config: config, classifier: DeafClassifier())
        let whisper = speech(3).map { $0 * 0.1 }  // RMS 0.01
        _ = chunker.append(silence(2) + whisper)
        let chunk = chunker.flush()
        #expect(chunk != nil)
        #expect((chunk?.duration ?? 0) >= 3)
    }

    @Test
    func speechOnsetSurvivesTrim_whileBelowMinSpeech() {
        var chunker = minSpeechChunker()
        _ = chunker.append(silence(5) + speech(2))
        let chunk = chunker.flush()
        // 2 s of speech plus at most the kept leading silence.
        let duration = chunk?.duration ?? 0
        #expect(duration >= 2 && duration < 3.1)
    }

    // Review 2026-11, finding 4: audible audio the VAD scores as non-speech (real
    // whispering) was cut every ~5 s with no overlap and reported as a 15 s pause.
    @Test
    func continuousWhisper_isNotCutAsPauses_norReportedAsParagraphs() {
        var config = LiveChunker.Config()
        config.minSpeechSeconds = 0.25
        var chunker = LiveChunker(config: config, classifier: DeafClassifier())
        let whisper = speech(40).map { $0 * 0.08 }  // RMS 0.008: audible, "not speech"
        let chunks = chunker.append(whisper)
        #expect(chunks.count == 1)
        #expect(chunks.first?.trailingOverlap == 2)
        #expect(abs((chunks.first?.duration ?? 0) - 28) < 0.1)
        let last = chunker.flush()
        #expect(last?.leadingOverlap == 2)
        #expect((chunks + [last].compactMap { $0 }).allSatisfy { $0.pauseBefore == 0 })
    }

    @Test
    func whisperWithARealPause_stillCutsAtThePause() {
        var config = LiveChunker.Config()
        config.minSpeechSeconds = 0.25
        var chunker = LiveChunker(config: config, classifier: DeafClassifier())
        let whisper: (Double) -> [Float] = { self.speech($0).map { $0 * 0.08 } }
        let chunks = chunker.append(whisper(12) + silence(1) + whisper(3))
        #expect(chunks.count == 1)
        #expect(chunks.first?.trailingOverlap == 0)
        let duration = chunks.first?.duration ?? 0
        #expect(duration > 12 && duration < 13)
    }
}
