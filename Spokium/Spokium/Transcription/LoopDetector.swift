import Foundation

// Detects whisper's "stuck in a loop" hallucination at the segment level.
// Failure mode the model exhibits with WHISPER_SAMPLING_GREEDY (temperature 0):
// once it decides to repeat a phrase, it keeps emitting that same phrase as a
// new segment every couple of seconds until the recording ends. The repetition
// often replaces real audio mid-utterance.
//
// Detection is structural: ≥ runThreshold consecutive *trimmed, non-empty*
// segment texts that are byte-identical. Empty segments (filtered upstream by
// `no_speech_prob`) don't reset the run because they represent silence, not
// new content.
nonisolated enum LoopDetector {
    static let runThreshold = 5

    static func hasLoop(segmentTexts: [String]) -> Bool {
        let cleaned = segmentTexts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard cleaned.count >= runThreshold else { return false }
        var run = 1
        for i in 1..<cleaned.count {
            if cleaned[i] == cleaned[i - 1] {
                run += 1
                if run >= runThreshold { return true }
            } else {
                run = 1
            }
        }
        return false
    }
}
