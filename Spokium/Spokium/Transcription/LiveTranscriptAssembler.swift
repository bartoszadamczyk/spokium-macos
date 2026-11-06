import Foundation

nonisolated struct TimedWord: Sendable, Equatable {
    // Raw whisper text, including its leading space when it starts a new word.
    let text: String
    // Seconds from the start of the chunk.
    let start: Double
}

// Stitches per-chunk transcripts from LiveChunker back into one text.
//
// - Overlapped seams (forced cuts): both chunks transcribed the same overlapSeconds of
//   audio. The earlier chunk keeps words starting before the overlap midpoint, the
//   later one keeps words from the midpoint on. Whisper treats every chunk start as a
//   sentence start, so a capitalised first word after a non-terminal seam is lowered.
// - Pause seams: chunks are joined with a space, or a paragraph break when the pause
//   is at least paragraphPauseSeconds and paragraph splitting is on.
nonisolated struct LiveTranscriptAssembler {
    struct ChunkInfo {
        let duration: Double
        let leadingOverlap: Double
        let trailingOverlap: Double
        let pauseBefore: Double
    }

    let paragraphSplitting: Bool
    let paragraphPauseSeconds: Double
    private(set) var text = ""

    init(paragraphSplitting: Bool, paragraphPauseSeconds: Double) {
        self.paragraphSplitting = paragraphSplitting
        self.paragraphPauseSeconds = paragraphPauseSeconds
    }

    mutating func append(text chunkText: String, words: [TimedWord], info: ChunkInfo) {
        var piece = trimmedPiece(text: chunkText, words: words, info: info)
        guard !piece.isEmpty else { return }

        guard !text.isEmpty else {
            text = piece
            return
        }

        if info.leadingOverlap > 0 {
            if !Self.endsSentence(text) { piece = Self.lowercasingSentenceStart(piece) }
            text += " " + piece
        } else if paragraphSplitting, info.pauseBefore >= paragraphPauseSeconds {
            text += "\n\n" + piece
        } else {
            text += " " + piece
        }
    }

    // Last `maxCharacters` of the assembled text, cut at a word boundary. Fed back to
    // whisper as initial_prompt for the next chunk to keep casing and names consistent.
    func tail(maxCharacters: Int = 200) -> String {
        guard text.count > maxCharacters else { return text }
        let start = text.index(text.endIndex, offsetBy: -maxCharacters)
        var suffix = text[start...]
        let startsMidWord = !text[text.index(before: start)].isWhitespace
        if startsMidWord, let space = suffix.firstIndex(where: \.isWhitespace) {
            suffix = suffix[space...]
        }
        return suffix.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func trimmedPiece(text chunkText: String, words: [TimedWord], info: ChunkInfo) -> String {
        guard info.leadingOverlap > 0 || info.trailingOverlap > 0, !words.isEmpty else {
            return chunkText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let from = info.leadingOverlap / 2
        let until = info.duration - info.trailingOverlap / 2
        return words
            .filter { (info.leadingOverlap == 0 || $0.start >= from) && (info.trailingOverlap == 0 || $0.start < until) }
            .map(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return true }
        return ".!?…".contains(last)
    }

    // "The" → "the", but leave "I", acronyms ("NASA") and single letters alone.
    private static func lowercasingSentenceStart(_ piece: String) -> String {
        let firstWord = piece.prefix { !$0.isWhitespace && !$0.isPunctuation }
        guard firstWord.count >= 2,
              let first = firstWord.first, first.isUppercase,
              firstWord.dropFirst().allSatisfy({ !$0.isUppercase })
        else { return piece }
        return first.lowercased() + piece.dropFirst()
    }
}
