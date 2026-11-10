import Foundation
import Testing

@testable import Spokium

@MainActor
struct SileroSpeechClassifierTests {
    private func classifier() throws -> SileroSpeechClassifier {
        try #require(SileroSpeechClassifier(), "bundled Silero model should load")
    }

    private func noise(_ seconds: Double, amplitude: Float) -> [Float] {
        var generator = SystemRandomNumberGenerator()
        return (0..<Int(seconds * 16_000)).map { _ in Float.random(in: -amplitude...amplitude, using: &generator) }
    }

    @Test
    func returnsOneFlagPerWindow() throws {
        let vad = try classifier()
        let flags = vad.classify(ArraySlice(repeating: 0, count: 512 * 31))
        #expect(flags.count == 31)
    }

    @Test
    func silence_isNotSpeech() throws {
        let vad = try classifier()
        #expect(!vad.classify(ArraySlice(repeating: 0, count: 512 * 100)).contains(true))
    }

    // The point of using a VAD: loud broadband noise clears the RMS threshold easily
    // but isn't speech.
    @Test
    func loudNoise_isSpeechForRMS_butNotForSilero() throws {
        let audio = noise(3, amplitude: 0.2)
        let usable = audio.count / 512 * 512
        let rms = RMSSpeechClassifier(windowSamples: 512).classify(audio[0..<usable])
        let silero = try classifier().classify(audio[0..<usable])
        #expect(rms.allSatisfy { $0 })
        #expect(Double(silero.filter { $0 }.count) / Double(silero.count) < 0.1)
    }

    @Test
    func streamingBatches_matchOnePass() throws {
        let audio = Array((noise(2, amplitude: 0.05) + Array(repeating: 0, count: 16_000)).prefix(512 * 90))
        let whole = try classifier()
        let streamed = try classifier()
        let expected = whole.classify(audio[...])
        var actual: [Bool] = []
        for start in stride(from: 0, to: audio.count, by: 512 * 15) {
            actual += streamed.classify(audio[start..<min(start + 512 * 15, audio.count)])
        }
        #expect(actual == expected)
    }

    @Test
    func halfSecondBatch_isCheapEnoughForTheMainThread() throws {
        let vad = try classifier()
        let batch = noise(0.5, amplitude: 0.05)
        let usable = batch.count / 512 * 512
        let elapsed = ContinuousClock().measure { _ = vad.classify(batch[0..<usable]) }
        print("Silero VAD: 0.5 s batch in \(elapsed)")
        #expect(elapsed < .milliseconds(50))
    }

    // Transcriber runs it over every chunk / whole file for the no-speech check and
    // paragraph breaks; measured ~50 ms for 30 s in a debug build.
    @Test
    func thirtySeconds_classifyQuickly() throws {
        let vad = try classifier()
        let audio = noise(30, amplitude: 0.05)
        let usable = audio.count / 512 * 512
        let elapsed = ContinuousClock().measure { _ = vad.classify(audio[0..<usable]) }
        #expect(elapsed < .milliseconds(500))
    }
}
