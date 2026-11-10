import Foundation

enum SilenceDetector {
    // Walks samples in 50ms windows, computes RMS energy, and records a break
    // time (in seconds, at the midpoint of the silence run) for each contiguous
    // low-energy run that lasts at least `minSilenceDuration`. Trailing silence
    // that runs to the end of the buffer is not reported as a break.
    nonisolated static func breaks(
        samples: [Float],
        sampleRate: Int,
        minSilenceDuration: Double,
        rmsThreshold: Float = 0.01
    ) -> [Double] {
        let windowSize = sampleRate / 20 // 50ms windows
        guard windowSize > 0 else { return [] }
        let usable = samples.count / windowSize * windowSize
        let speech = RMSSpeechClassifier(windowSamples: windowSize, silenceRMS: rmsThreshold)
            .classify(samples[0..<usable])
        let windowSeconds = Double(windowSize) / Double(sampleRate)
        return breaks(speech: speech, windowSeconds: windowSeconds, minSilenceDuration: minSilenceDuration)
    }

    // Same rule over per-window speech flags (e.g. from Silero VAD).
    nonisolated static func breaks(speech: [Bool], windowSeconds: Double, minSilenceDuration: Double) -> [Double] {
        guard windowSeconds > 0 else { return [] }
        // Epsilon: 3.0 / 0.05 is 59.999… in floating point.
        let minSilenceWindows = Int(minSilenceDuration / windowSeconds + 1e-9)
        var breaks: [Double] = []
        var silenceStart: Int?

        for (index, isSpeech) in speech.enumerated() {
            if !isSpeech {
                if silenceStart == nil { silenceStart = index }
            } else if let start = silenceStart {
                let duration = index - start
                if duration >= minSilenceWindows {
                    breaks.append(Double(start + duration / 2) * windowSeconds)
                }
                silenceStart = nil
            }
        }
        return breaks
    }
}
