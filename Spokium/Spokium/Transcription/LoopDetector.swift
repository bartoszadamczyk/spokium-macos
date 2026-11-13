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

    // Catches the other loop shape: one segment that repeats a short phrase, e.g.
    // "and then and then and then and then". Words are compared case- and
    // punctuation-insensitively. A single word needs more repeats than a phrase
    // because short real repetitions ("no, no, no") do happen.
    static let singleWordRepeatThreshold = 6
    static let phraseRepeatThreshold = 4
    static let maxPhraseLength = 4

    // Collapses a word or short phrase repeated back-to-back (at the thresholds above) to
    // one occurrence, line by line so paragraph breaks survive. Used when a phrase loop
    // persists after the temperature retry.
    static func collapseRepeats(_ text: String) -> String {
        text.components(separatedBy: "\n").map(collapseLine).joined(separator: "\n")
    }

    private static func collapseLine(_ line: String) -> String {
        var words = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        func key(_ w: String) -> String { w.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        for n in 1...maxPhraseLength {
            let needed = n == 1 ? singleWordRepeatThreshold : phraseRepeatThreshold
            var i = 0
            while i + n <= words.count {
                let phrase = words[i..<(i + n)].map(key)
                var repeats = 1
                while i + (repeats + 1) * n <= words.count,
                      words[(i + repeats * n)..<(i + (repeats + 1) * n)].map(key) == phrase {
                    repeats += 1
                }
                if repeats >= needed, !phrase.allSatisfy(\.isEmpty) {
                    // Keep the last copy: it carries the run's trailing punctuation.
                    words.removeSubrange(i..<(i + (repeats - 1) * n))
                }
                i += 1
            }
        }
        return words.joined(separator: " ")
    }

    static func hasRepeatedPhrase(_ text: String) -> Bool {
        let words = text
            .split(whereSeparator: \.isWhitespace)
            .map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
        guard words.count >= phraseRepeatThreshold else { return false }

        for n in 1...maxPhraseLength {
            let needed = n == 1 ? singleWordRepeatThreshold : phraseRepeatThreshold
            guard words.count >= n * needed else { continue }
            for start in 0...(words.count - n * needed) {
                var repeats = 1
                while start + (repeats + 1) * n <= words.count,
                      words[(start + repeats * n)..<(start + (repeats + 1) * n)] == words[start..<(start + n)] {
                    repeats += 1
                    if repeats >= needed { return true }
                }
            }
        }
        return false
    }
}
