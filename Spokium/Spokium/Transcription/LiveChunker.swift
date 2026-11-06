import Foundation

// Splits a live 16 kHz mono stream into chunks short enough for a single whisper
// window (≤ 30 s), so transcription can run while the user is still speaking.
//
// Cut preference, in order:
//   1. At a pause — once the chunk holds ≥ minChunkSeconds and the trailing silence
//      reaches pauseToCutSeconds, cut in the middle of that silence.
//   2. At the longest short gap in the last searchSeconds, once the chunk hits
//      maxChunkSeconds.
//   3. Forced cut at maxChunkSeconds, carrying overlapSeconds of audio into the next
//      chunk so LiveTranscriptAssembler can de-duplicate words at the seam.
//
// All cut positions are aligned to analysis windows so the per-window RMS array can
// be sliced alongside the samples.
nonisolated struct LiveChunker {
    struct Config {
        var sampleRate: Double = 16_000
        var windowSeconds: Double = 0.05
        var silenceRMS: Float = 0.01
        var minChunkSeconds: Double = 10
        var maxChunkSeconds: Double = 28
        var pauseToCutSeconds: Double = 0.8
        var searchSeconds: Double = 8
        var minGapSeconds: Double = 0.2
        var overlapSeconds: Double = 2
        // Leading silence beyond this is dropped (and counted toward pauseBefore) so
        // chunks don't start with long stretches whisper likes to hallucinate over.
        var maxLeadingSilenceSeconds: Double = 0.5
    }

    struct Chunk: Equatable {
        let samples: [Float]
        // Seconds at the start that duplicate the end of the previous chunk.
        let leadingOverlap: Double
        // Seconds at the end that are duplicated at the start of the next chunk.
        let trailingOverlap: Double
        // Length of the pause separating this chunk from the previous one (0 for the
        // first chunk and for overlapped seams). Drives paragraph breaks.
        let pauseBefore: Double

        var duration: Double { Double(samples.count) / 16_000 }
    }

    let config: Config

    private var samples: [Float] = []
    private var windowRMS: [Float] = []
    private var leadingOverlap: Double = 0
    private var pauseCarriedIn: Double = 0
    private var trimmedSilence: Double = 0
    private var isFirstChunk = true

    init(config: Config = Config()) {
        self.config = config
    }

    private var windowSize: Int { max(1, Int(config.sampleRate * config.windowSeconds)) }
    private var hasSpeech: Bool { windowRMS.contains { $0 >= config.silenceRMS } }

    private var trailingSilentWindows: Int {
        var n = 0
        for rms in windowRMS.reversed() {
            guard rms < config.silenceRMS else { break }
            n += 1
        }
        return n
    }

    private var leadingSilentWindows: Int {
        windowRMS.prefix { $0 < config.silenceRMS }.count
    }

    mutating func append(_ newSamples: [Float]) -> [Chunk] {
        var out: [Chunk] = []
        samples.append(contentsOf: newSamples)
        let size = windowSize

        while windowRMS.count * size + size <= samples.count {
            let start = windowRMS.count * size
            var sum: Float = 0
            for i in start..<(start + size) { sum += samples[i] * samples[i] }
            windowRMS.append((sum / Float(size)).squareRoot())

            trimLeadingSilence()
            if let chunk = cutIfReady() { out.append(chunk) }
        }
        return out
    }

    // Emits whatever is left once recording stops. Returns nil if it holds no speech.
    mutating func flush() -> Chunk? {
        defer { reset() }
        guard hasSpeech else { return nil }
        return makeChunk(endWindow: windowRMS.count, sampleEnd: samples.count, trailingOverlap: 0)
    }

    private mutating func reset() {
        samples = []
        windowRMS = []
        leadingOverlap = 0
        pauseCarriedIn = 0
        trimmedSilence = 0
        isFirstChunk = true
    }

    private mutating func trimLeadingSilence() {
        guard leadingOverlap == 0, !hasSpeech else { return }
        let keep = Int((config.maxLeadingSilenceSeconds / config.windowSeconds).rounded())
        let excess = windowRMS.count - keep
        guard excess > 0 else { return }
        dropWindows(excess)
        trimmedSilence += Double(excess) * config.windowSeconds
    }

    private mutating func cutIfReady() -> Chunk? {
        guard hasSpeech else { return nil }
        let duration = Double(windowRMS.count) * config.windowSeconds
        let silentTail = trailingSilentWindows
        let pauseWindows = Int((config.pauseToCutSeconds / config.windowSeconds).rounded())

        if duration >= config.minChunkSeconds, silentTail >= pauseWindows {
            return cut(atWindow: windowRMS.count - silentTail / 2, carriedPause: Double(silentTail) * config.windowSeconds / 2)
        }

        guard duration >= config.maxChunkSeconds else { return nil }

        if let gap = longestGapInSearchRange() {
            return cut(atWindow: gap.mid, carriedPause: Double(gap.length) * config.windowSeconds / 2)
        }

        let overlapWindows = Int((config.overlapSeconds / config.windowSeconds).rounded())
        let end = windowRMS.count
        let chunk = makeChunk(endWindow: end, sampleEnd: end * windowSize, trailingOverlap: config.overlapSeconds)
        dropWindows(end - overlapWindows)
        leadingOverlap = config.overlapSeconds
        pauseCarriedIn = 0
        trimmedSilence = 0
        return chunk
    }

    private func longestGapInSearchRange() -> (mid: Int, length: Int)? {
        let searchWindows = Int((config.searchSeconds / config.windowSeconds).rounded())
        let minGap = max(1, Int((config.minGapSeconds / config.windowSeconds).rounded()))
        let from = max(0, windowRMS.count - searchWindows)
        var best: (mid: Int, length: Int)?
        var runStart: Int?
        for i in from...windowRMS.count {
            let silent = i < windowRMS.count && windowRMS[i] < config.silenceRMS
            if silent {
                if runStart == nil { runStart = i }
            } else if let start = runStart {
                let length = i - start
                if length >= minGap, length > (best?.length ?? 0) {
                    best = (start + length / 2, length)
                }
                runStart = nil
            }
        }
        return best
    }

    private mutating func cut(atWindow window: Int, carriedPause: Double) -> Chunk {
        let chunk = makeChunk(endWindow: window, sampleEnd: window * windowSize, trailingOverlap: 0)
        dropWindows(window)
        leadingOverlap = 0
        pauseCarriedIn = carriedPause
        trimmedSilence = 0
        return chunk
    }

    private mutating func makeChunk(endWindow: Int, sampleEnd: Int, trailingOverlap: Double) -> Chunk {
        let pause: Double
        if isFirstChunk || leadingOverlap > 0 {
            pause = 0
        } else {
            pause = pauseCarriedIn + trimmedSilence + Double(leadingSilentWindows) * config.windowSeconds
        }
        isFirstChunk = false
        return Chunk(
            samples: Array(samples[0..<min(sampleEnd, samples.count)]),
            leadingOverlap: leadingOverlap,
            trailingOverlap: trailingOverlap,
            pauseBefore: pause
        )
    }

    private mutating func dropWindows(_ count: Int) {
        guard count > 0 else { return }
        windowRMS.removeFirst(min(count, windowRMS.count))
        samples.removeFirst(min(count * windowSize, samples.count))
    }
}
