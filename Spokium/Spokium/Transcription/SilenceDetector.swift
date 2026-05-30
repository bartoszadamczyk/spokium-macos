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
        let minSilenceWindows = Int(minSilenceDuration * 20)
        var breaks: [Double] = []
        var silenceStart: Int?

        for windowIndex in 0..<(samples.count / windowSize) {
            let offset = windowIndex * windowSize
            let end = min(offset + windowSize, samples.count)
            var sumSq: Float = 0
            for i in offset..<end {
                sumSq += samples[i] * samples[i]
            }
            let rms = (sumSq / Float(end - offset)).squareRoot()

            if rms < rmsThreshold {
                if silenceStart == nil { silenceStart = windowIndex }
            } else {
                if let start = silenceStart {
                    let duration = windowIndex - start
                    if duration >= minSilenceWindows {
                        let midWindow = start + duration / 2
                        let timeSeconds = Double(midWindow * windowSize) / Double(sampleRate)
                        breaks.append(timeSeconds)
                    }
                    silenceStart = nil
                }
            }
        }
        return breaks
    }
}
