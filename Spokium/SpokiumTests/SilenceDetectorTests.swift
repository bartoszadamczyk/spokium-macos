import Testing
@testable import Spokium

@MainActor
struct SilenceDetectorTests {
    private let sampleRate = 16_000
    private let windowSize = 800 // 16000/20 = 50ms windows

    private func samples(loudWindows: Int = 0, silentWindows: Int = 0) -> [Float] {
        let loud = [Float](repeating: 0.5, count: loudWindows * windowSize)
        let silent = [Float](repeating: 0.0, count: silentWindows * windowSize)
        return loud + silent
    }

    private func pattern(_ runs: [(loud: Bool, windows: Int)]) -> [Float] {
        var out: [Float] = []
        for run in runs {
            let value: Float = run.loud ? 0.5 : 0.0
            out.append(contentsOf: [Float](repeating: value, count: run.windows * windowSize))
        }
        return out
    }

    @Test func emptySamples_producesNoBreaks() {
        let breaks = SilenceDetector.breaks(
            samples: [],
            sampleRate: sampleRate,
            minSilenceDuration: 1.0
        )
        #expect(breaks.isEmpty)
    }

    @Test func allLoud_producesNoBreaks() {
        let breaks = SilenceDetector.breaks(
            samples: samples(loudWindows: 100),
            sampleRate: sampleRate,
            minSilenceDuration: 1.0
        )
        #expect(breaks.isEmpty)
    }

    @Test func allSilent_producesNoBreaks() {
        // No transition back to loud → silence is never "closed", no break recorded.
        let breaks = SilenceDetector.breaks(
            samples: samples(silentWindows: 100),
            sampleRate: sampleRate,
            minSilenceDuration: 1.0
        )
        #expect(breaks.isEmpty)
    }

    @Test func longSilenceBetweenSpeech_producesOneBreak() {
        // 1 loud window, 40 silent windows (2.0 s), 1 loud window. Threshold 1.0 s.
        let breaks = SilenceDetector.breaks(
            samples: pattern([(true, 1), (false, 40), (true, 1)]),
            sampleRate: sampleRate,
            minSilenceDuration: 1.0
        )
        #expect(breaks.count == 1)
    }

    @Test func shortSilenceBetweenSpeech_producesNoBreak() {
        // 0.5 s silence, threshold 1.0 s → not long enough.
        let breaks = SilenceDetector.breaks(
            samples: pattern([(true, 1), (false, 10), (true, 1)]),
            sampleRate: sampleRate,
            minSilenceDuration: 1.0
        )
        #expect(breaks.isEmpty)
    }

    @Test func multipleSilenceGaps_produceMultipleBreaks() {
        let breaks = SilenceDetector.breaks(
            samples: pattern([
                (true, 1), (false, 40), (true, 5), (false, 40), (true, 1)
            ]),
            sampleRate: sampleRate,
            minSilenceDuration: 1.0
        )
        #expect(breaks.count == 2)
    }

    @Test func trailingSilence_isNotRecordedAsBreak() {
        // Silence at the end runs to EOF without transitioning back to loud,
        // so no break is recorded. This is the current intentional behaviour.
        let breaks = SilenceDetector.breaks(
            samples: pattern([(true, 1), (false, 60)]),
            sampleRate: sampleRate,
            minSilenceDuration: 1.0
        )
        #expect(breaks.isEmpty)
    }

    @Test func breakTimestamp_isMidpointOfSilenceRun() {
        // 1 loud window (0-50ms), 40 silent windows (50-2050ms), 1 loud window.
        // silenceStart = window 1, duration = 40, midWindow = 1 + 20 = 21.
        // timeSeconds = 21 * 800 / 16000 = 1.05
        let breaks = SilenceDetector.breaks(
            samples: pattern([(true, 1), (false, 40), (true, 1)]),
            sampleRate: sampleRate,
            minSilenceDuration: 1.0
        )
        #expect(breaks.count == 1)
        let first = breaks.first ?? 0
        #expect(abs(first - 1.05) < 0.001)
    }
}
