import Foundation
import Testing
@testable import Spokium

@MainActor
struct TranscriptHistoryTests {
    @Test func add_storesNewEntry_atFront() {
        let h = TranscriptHistory()
        h.add("first")
        h.add("second")

        #expect(h.entries.count == 2)
        #expect(h.entries[0].text == "second")
        #expect(h.entries[1].text == "first")
    }

    @Test func add_emptyOrWhitespaceText_isIgnored() {
        let h = TranscriptHistory()
        h.add("")
        h.add("   ")
        h.add("\n\n")

        #expect(h.entries.isEmpty)
    }

    @Test func add_capsAtMaxCount_oldestDropped() {
        let h = TranscriptHistory(maxCount: 3)
        h.add("a")
        h.add("b")
        h.add("c")
        h.add("d")

        #expect(h.entries.count == 3)
        #expect(h.entries.map(\.text) == ["d", "c", "b"])
    }

    @Test func prune_removesEntriesOlderThanRetention() {
        let h = TranscriptHistory(maxCount: 5, retention: 60)
        h.add("a")

        // Simulate 90 seconds passing.
        h.prune(now: Date().addingTimeInterval(90))
        #expect(h.entries.isEmpty)
    }

    @Test func prune_keepsEntriesWithinRetention() {
        let h = TranscriptHistory(maxCount: 5, retention: 60)
        h.add("a")

        // 30 s later — still within retention.
        h.prune(now: Date().addingTimeInterval(30))
        #expect(h.entries.count == 1)
    }

    @Test func clear_emptiesStore() {
        let h = TranscriptHistory()
        h.add("a")
        h.add("b")
        h.clear()

        #expect(h.entries.isEmpty)
    }

    @Test func preview_shortText_returnsAsIs() {
        let h = TranscriptHistory()
        h.add("hello world")
        #expect(h.entries.first?.preview == "hello world")
    }

    @Test func preview_longText_isTruncatedWithEllipsis() {
        let long = String(repeating: "abcdefghij", count: 10) // 100 chars
        let h = TranscriptHistory()
        h.add(long)

        let preview = h.entries.first?.preview ?? ""
        #expect(preview.count == 41) // 40 chars + ellipsis
        #expect(preview.hasSuffix("…"))
    }

    @Test func preview_collapsesNewlines_intoSpaces() {
        let h = TranscriptHistory()
        h.add("line one\nline two\nline three")

        #expect(h.entries.first?.preview == "line one line two line three")
    }
}
