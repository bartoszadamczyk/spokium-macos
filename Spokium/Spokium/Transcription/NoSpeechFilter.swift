import Foundation

// Decides whether a whisper segment is a "no speech" hallucination to drop.
//
// Dropping on no_speech_prob alone cut off real speech: a short final sentence in a
// window that's mostly padding often scores > 0.6 even though it was decoded with
// confidence. OpenAI's reference rule only treats a segment as silence when the
// no-speech probability is high *and* the decoder was unsure of the text.
nonisolated enum NoSpeechFilter {
    static let noSpeechThreshold: Float = 0.6
    static let logProbThreshold: Float = -1.0

    static func shouldDrop(noSpeechProb: Float, averageLogProb: Float?) -> Bool {
        guard noSpeechProb > noSpeechThreshold else { return false }
        guard let averageLogProb else { return true }
        return averageLogProb < logProbThreshold
    }
}
