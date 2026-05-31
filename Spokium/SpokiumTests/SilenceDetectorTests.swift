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

    // MARK: - Edge cases

    @Test func silenceExactlyAtThreshold_isDetected() {
        // minSilenceDuration 1.0 s = 20 windows. Provide exactly 20 silent windows.
        // Duration check is `>= minSilenceWindows`, so exact match counts.
        let breaks = SilenceDetector.breaks(
            samples: pattern([(true, 1), (false, 20), (true, 1)]),
            sampleRate: sampleRate,
            minSilenceDuration: 1.0
        )
        #expect(breaks.count == 1)
    }

    @Test func silenceOneWindowBelowThreshold_isNotDetected() {
        // 19 silent windows at threshold of 1.0 s (20 windows) → just under.
        let breaks = SilenceDetector.breaks(
            samples: pattern([(true, 1), (false, 19), (true, 1)]),
            sampleRate: sampleRate,
            minSilenceDuration: 1.0
        )
        #expect(breaks.isEmpty)
    }

    @Test func verySmallThreshold_singleWindowSilence_isDetected() {
        // minSilenceDuration 0.05 s = 1 window. Even a 1-window silence counts.
        let breaks = SilenceDetector.breaks(
            samples: pattern([(true, 1), (false, 1), (true, 1)]),
            sampleRate: sampleRate,
            minSilenceDuration: 0.05
        )
        #expect(breaks.count == 1)
    }

    @Test func oddSampleRate_doesNotCrashAndStillDetects() {
        // 16001 / 20 = 800 (rounded down). Window size is still 800. Pattern
        // construction uses 16001 samples per "second" but the detector reads
        // its own sampleRate to find the window size, so the test still works.
        let sr = 16_001
        let windowSize = sr / 20
        let loud = [Float](repeating: 0.5, count: windowSize)
        let silent = [Float](repeating: 0.0, count: 40 * windowSize)
        let samples = loud + silent + loud

        let breaks = SilenceDetector.breaks(
            samples: samples,
            sampleRate: sr,
            minSilenceDuration: 1.0
        )
        #expect(breaks.count == 1)
    }

    @Test func zeroSampleRate_producesNoBreaks() {
        // windowSize = 0 → guard in production returns []. Defensive check.
        let breaks = SilenceDetector.breaks(
            samples: samples(silentWindows: 10),
            sampleRate: 0,
            minSilenceDuration: 1.0
        )
        #expect(breaks.isEmpty)
    }

    @Test func silenceStartingFromBufferStart_isDetected_whenFollowedByLoud() {
        // Silence starts at window 0 (silenceStart=0), 40 windows, then loud.
        // Should produce a break at midpoint (window 20).
        let breaks = SilenceDetector.breaks(
            samples: pattern([(false, 40), (true, 1)]),
            sampleRate: sampleRate,
            minSilenceDuration: 1.0
        )
        #expect(breaks.count == 1)
        let first = breaks.first ?? -1
        // midWindow = 0 + 20 = 20. timeSeconds = 20 * 800 / 16000 = 1.0.
        #expect(abs(first - 1.0) < 0.001)
    }
}
