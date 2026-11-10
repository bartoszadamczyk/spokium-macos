import AppKit
import Testing

@testable import Spokium

@MainActor
struct ClipboardRestorerTests {
    // A private, uniquely named pasteboard so tests never touch the user's clipboard.
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("spokium-tests-\(UUID().uuidString)"))
    }

    private func put(_ text: String, on pasteboard: NSPasteboard) -> Int {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return pasteboard.changeCount
    }

    @Test
    func restoreNow_putsOriginalBack() {
        let pb = makePasteboard()
        _ = put("original", on: pb)
        let restorer = ClipboardRestorer(pasteboard: pb, delay: .seconds(60))

        let original = restorer.captureOriginal()
        let count = put("transcript", on: pb)
        restorer.scheduleRestore(original, expectedChangeCount: count)
        #expect(pb.string(forType: .string) == "transcript")

        restorer.restoreNow()
        #expect(pb.string(forType: .string) == "original")
        #expect(restorer.hasPendingRestore == false)
    }

    @Test
    func userCopyInTheMeantime_winsOverRestore() {
        let pb = makePasteboard()
        _ = put("original", on: pb)
        let restorer = ClipboardRestorer(pasteboard: pb, delay: .seconds(60))

        let original = restorer.captureOriginal()
        let count = put("transcript", on: pb)
        restorer.scheduleRestore(original, expectedChangeCount: count)
        _ = put("something the user copied", on: pb)

        restorer.restoreNow()
        #expect(pb.string(forType: .string) == "something the user copied")
    }

    @Test
    func secondTranscriptBeforeRestore_keepsFirstOriginal() {
        let pb = makePasteboard()
        _ = put("original", on: pb)
        let restorer = ClipboardRestorer(pasteboard: pb, delay: .seconds(60))

        let first = restorer.captureOriginal()
        let firstCount = put("transcript 1", on: pb)
        restorer.scheduleRestore(first, expectedChangeCount: firstCount)

        let second = restorer.captureOriginal()
        let secondCount = put("transcript 2", on: pb)
        restorer.scheduleRestore(second, expectedChangeCount: secondCount)

        restorer.restoreNow()
        #expect(pb.string(forType: .string) == "original")
    }

    @Test
    func restoreFiresAfterDelay() async throws {
        let pb = makePasteboard()
        _ = put("original", on: pb)
        let restorer = ClipboardRestorer(pasteboard: pb, delay: .milliseconds(50))

        let original = restorer.captureOriginal()
        let count = put("transcript", on: pb)
        restorer.scheduleRestore(original, expectedChangeCount: count)

        // Poll rather than sleep a fixed amount: under a loaded parallel test run the
        // restore task can be scheduled late.
        let deadline = ContinuousClock.now + .seconds(3)
        while pb.string(forType: .string) != "original", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        // The restore task holds the restorer weakly (the app's is a long-lived shared
        // instance); without this the local may be released after its last use above
        // and the restore never fires.
        withExtendedLifetime(restorer) {}
        #expect(pb.string(forType: .string) == "original")
    }

    @Test
    func restoreNow_withNothingPending_isNoOp() {
        let pb = makePasteboard()
        _ = put("untouched", on: pb)
        let restorer = ClipboardRestorer(pasteboard: pb, delay: .seconds(60))
        restorer.restoreNow()
        #expect(pb.string(forType: .string) == "untouched")
    }
}
