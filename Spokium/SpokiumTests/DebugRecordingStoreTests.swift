import Foundation
import Testing
@testable import Spokium

@MainActor
struct DebugRecordingStoreTests {
    private func segment(
        _ index: Int32,
        _ start: Double,
        _ end: Double,
        _ nsp: Float,
        _ text: String
    ) -> DebugSegment {
        DebugSegment(
            index: index,
            startSeconds: start,
            endSeconds: end,
            noSpeechProb: nsp,
            text: text
        )
    }

    @Test func renderSidecar_singleAudioFile_emitsHeaderAndTable() {
        let md = DebugRecordingStore.renderSidecar(
            audioFileNames: ["whisper-2026-06-01T00-00-00.caf"],
            segments: [
                segment(0, 0.0, 2.4, 0.012, "Hello world."),
                segment(1, 2.4, 4.8, 0.005, "Another sentence here."),
            ],
            now: Date(timeIntervalSince1970: 0)
        )

        #expect(md.contains("# Whisper Debug Log"))
        #expect(md.contains("**Audio**: whisper-2026-06-01T00-00-00.caf"))
        #expect(md.contains("| # | start | end | no_speech_prob | text |"))
        #expect(md.contains("| 0 | 0.00s | 2.40s | 0.012 | Hello world. |"))
        #expect(md.contains("| 1 | 2.40s | 4.80s | 0.005 | Another sentence here. |"))
    }

    @Test func renderSidecar_multipleAudioFiles_listsAll() {
        let md = DebugRecordingStore.renderSidecar(
            audioFileNames: ["a.caf", "b.caf", "c.caf"],
            segments: [segment(0, 0.0, 1.0, 0.01, "test")],
            now: Date(timeIntervalSince1970: 0)
        )

        #expect(md.contains("**Audio segments**: a.caf, b.caf, c.caf"))
    }

    @Test func renderSidecar_emptySegments_emitsPlaceholder() {
        let md = DebugRecordingStore.renderSidecar(
            audioFileNames: ["x.caf"],
            segments: [],
            now: Date(timeIntervalSince1970: 0)
        )

        #expect(md.contains("_(no segments returned)_"))
        #expect(!md.contains("| # | start | end |"))
    }

    @Test func renderSidecar_pipesInText_areEscapedToAvoidBreakingTable() {
        let md = DebugRecordingStore.renderSidecar(
            audioFileNames: ["x.caf"],
            segments: [segment(0, 0.0, 1.0, 0.01, "left | right")],
            now: Date(timeIntervalSince1970: 0)
        )

        // The pipe must be escaped so it doesn't break the markdown table.
        #expect(md.contains("left \\| right"))
    }

    @Test func renderSidecar_newlinesInText_areCollapsedToSpaces() {
        let md = DebugRecordingStore.renderSidecar(
            audioFileNames: ["x.caf"],
            segments: [segment(0, 0.0, 1.0, 0.01, "line one\nline two")],
            now: Date(timeIntervalSince1970: 0)
        )

        #expect(md.contains("line one line two"))
        #expect(!md.contains("line one\nline two"))
    }
}
