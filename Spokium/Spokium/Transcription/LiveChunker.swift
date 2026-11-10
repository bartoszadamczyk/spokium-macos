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
// "Silence" is decided per analysis window by a SpeechClassifier: Silero VAD when its
// model loads, RMS energy otherwise. All cut positions are aligned to those windows so
// the per-window flags can be sliced alongside the samples.
nonisolated struct LiveChunker {
    struct Config {
        var sampleRate: Double = 16_000
        var minChunkSeconds: Double = 10
        var maxChunkSeconds: Double = 28
        var pauseToCutSeconds: Double = 0.8
        var searchSeconds: Double = 8
        var minGapSeconds: Double = 0.2
        var overlapSeconds: Double = 2
        // Leading silence beyond this is dropped (and counted toward pauseBefore) so
        // chunks don't start with long stretches whisper likes to hallucinate over.
        var maxLeadingSilenceSeconds: Double = 0.5
        // A chunk needs this much speech in total to be emitted. Keeps lone VAD blips
        // (a cough, a click) from becoming whisper calls that hallucinate.
        var minSpeechSeconds: Double = 0
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

    private var classifier: any SpeechClassifier
    private var samples: [Float] = []
    private var windowSpeech: [Bool] = []
    // RMS ≥ audibleRMS per window, regardless of classifier. Keep/drop decisions use speech OR
    // loud: Silero scores real whispering (breath, room noise) as non-speech, and it must
    // never throw away audio the old RMS check would have kept. Cut placement still
    // follows windowSpeech alone, so noise doesn't block pause cuts.
    private var windowLoud: [Bool] = []
    private var leadingOverlap: Double = 0
    private var pauseCarriedIn: Double = 0
    private var trimmedSilence: Double = 0
    private var isFirstChunk = true

    init(config: Config = Config(), classifier: any SpeechClassifier = RMSSpeechClassifier()) {
        self.config = config
        self.classifier = classifier
    }

    private var windowSize: Int { max(1, classifier.windowSamples) }
    private var windowSeconds: Double { Double(windowSize) / config.sampleRate }

    // Worth transcribing: enough classified speech, or anything audible.
    private var hasContent: Bool {
        hasSpeech || windowLoud.contains(true)
    }

    private var hasSpeech: Bool {
        let needed = max(1, Int((config.minSpeechSeconds / windowSeconds).rounded()))
        var count = 0
        for speech in windowSpeech where speech {
            count += 1
            if count >= needed { return true }
        }
        return false
    }

    private var trailingSilentWindows: Int {
        windowSpeech.reversed().prefix { !$0 }.count
    }

    private var leadingSilentWindows: Int {
        windowSpeech.prefix { !$0 }.count
    }

    mutating func append(_ newSamples: [Float]) -> [Chunk] {
        var out: [Chunk] = []
        samples.append(contentsOf: newSamples)
        let size = windowSize
        let classifiedEnd = windowSpeech.count * size
        let completeEnd = samples.count / size * size
        guard completeEnd > classifiedEnd else { return out }

        // Classified as one batch (cheaper for the VAD), then fed in window by window
        // so cuts land exactly where they would with per-window processing.
        let slice = samples[classifiedEnd..<completeEnd]
        let flags = classifier.classify(slice)
        let loud = RMSSpeechClassifier(windowSamples: size, silenceRMS: RMSSpeechClassifier.audibleRMS).classify(slice)
        for (speech, isLoud) in zip(flags, loud) {
            windowSpeech.append(speech)
            windowLoud.append(isLoud)
            trimLeadingSilence()
            if let chunk = cutIfReady() { out.append(chunk) }
        }
        return out
    }

    // Emits whatever is left once recording stops. Returns nil if it holds no speech.
    mutating func flush() -> Chunk? {
        defer { reset() }
        guard hasContent else { return nil }
        return makeChunk(endWindow: windowSpeech.count, sampleEnd: samples.count, trailingOverlap: 0)
    }

    private mutating func reset() {
        classifier.reset()
        samples = []
        windowSpeech = []
        windowLoud = []
        leadingOverlap = 0
        pauseCarriedIn = 0
        trimmedSilence = 0
        isFirstChunk = true
    }

    private mutating func trimLeadingSilence() {
        guard leadingOverlap == 0, !hasContent else { return }
        // Also keep the speech seen so far: while it's still under minSpeechSeconds the
        // chunk doesn't count as speech yet, but its onset must survive the trim.
        let keepSeconds = config.maxLeadingSilenceSeconds + config.minSpeechSeconds * 2
        let keep = Int((keepSeconds / windowSeconds).rounded())
        let excess = windowSpeech.count - keep
        guard excess > 0 else { return }
        dropWindows(excess)
        trimmedSilence += Double(excess) * windowSeconds
    }

    private mutating func cutIfReady() -> Chunk? {
        guard hasContent else { return nil }
        let duration = Double(windowSpeech.count) * windowSeconds
        let silentTail = trailingSilentWindows
        let pauseWindows = Int((config.pauseToCutSeconds / windowSeconds).rounded())

        if duration >= config.minChunkSeconds, silentTail >= pauseWindows {
            return cut(atWindow: windowSpeech.count - silentTail / 2, carriedPause: Double(silentTail) * windowSeconds / 2)
        }

        guard duration >= config.maxChunkSeconds else { return nil }

        if let gap = longestGapInSearchRange() {
            return cut(atWindow: gap.mid, carriedPause: Double(gap.length) * windowSeconds / 2)
        }

        let overlapWindows = Int((config.overlapSeconds / windowSeconds).rounded())
        let end = windowSpeech.count
        let chunk = makeChunk(endWindow: end, sampleEnd: end * windowSize, trailingOverlap: config.overlapSeconds)
        dropWindows(end - overlapWindows)
        leadingOverlap = config.overlapSeconds
        pauseCarriedIn = 0
        trimmedSilence = 0
        return chunk
    }

    private func longestGapInSearchRange() -> (mid: Int, length: Int)? {
        let searchWindows = Int((config.searchSeconds / windowSeconds).rounded())
        let minGap = max(1, Int((config.minGapSeconds / windowSeconds).rounded()))
        let from = max(0, windowSpeech.count - searchWindows)
        var best: (mid: Int, length: Int)?
        var runStart: Int?
        for i in from...windowSpeech.count {
            let silent = i < windowSpeech.count && !windowSpeech[i]
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
            pause = pauseCarriedIn + trimmedSilence + Double(leadingSilentWindows) * windowSeconds
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
        windowSpeech.removeFirst(min(count, windowSpeech.count))
        windowLoud.removeFirst(min(count, windowLoud.count))
        samples.removeFirst(min(count * windowSize, samples.count))
    }
}

// Decides, per fixed-size window of 16 kHz samples, whether it holds speech.
nonisolated protocol SpeechClassifier {
    var windowSamples: Int { get }
    // samples.count is a multiple of windowSamples; returns one flag per window.
    mutating func classify(_ samples: ArraySlice<Float>) -> [Bool]
    // Called between recordings so state from one doesn't leak into the next.
    mutating func reset()
}

nonisolated struct RMSSpeechClassifier: SpeechClassifier {
    var windowSamples = 800
    var silenceRMS: Float = 0.01
    // Lower bar for "don't throw this away": close-mic whispering sits around 0.005–0.02,
    // a quiet room below ~0.003.
    static let audibleRMS: Float = 0.005

    func classify(_ samples: ArraySlice<Float>) -> [Bool] {
        stride(from: samples.startIndex, to: samples.endIndex, by: windowSamples).map { start in
            let window = samples[start..<min(start + windowSamples, samples.endIndex)]
            let sum = window.reduce(Float(0)) { $0 + $1 * $1 }
            return (sum / Float(window.count)).squareRoot() >= silenceRMS
        }
    }

    func reset() {}
}
