import Testing

@testable import Spokium

struct LoopDetectorTests {

    @Test
    func emptyArrayIsNotLoop() {
        #expect(LoopDetector.hasLoop(segmentTexts: []) == false)
    }

    @Test
    func belowThresholdIsNotLoop() {
        let texts = Array(repeating: " 1/2 tbsp vanilla extract", count: 4)
        #expect(LoopDetector.hasLoop(segmentTexts: texts) == false)
    }

    @Test
    func atThresholdIsLoop() {
        let texts = Array(repeating: " 1/2 tbsp vanilla extract", count: 5)
        #expect(LoopDetector.hasLoop(segmentTexts: texts) == true)
    }

    @Test
    func realWorldVanillaExtractCaseIsLoop() {
        // From an actual debug log: one Norwegian preamble segment followed by 22 identical
        // English repetitions. Threshold 5 must fire on the trailing run.
        var texts: [String] = [" 1/2 tbsp vanilleekstraktspulver"]
        texts.append(contentsOf: Array(repeating: " 1/2 tbsp vanilla extract", count: 22))
        #expect(LoopDetector.hasLoop(segmentTexts: texts) == true)
    }

    @Test
    func whitespaceDifferencesDontResetRun() {
        let texts = [
            " 1/2 tbsp vanilla extract",
            "1/2 tbsp vanilla extract ",
            " 1/2 tbsp vanilla extract ",
            "1/2 tbsp vanilla extract",
            " 1/2 tbsp vanilla extract",
        ]
        #expect(LoopDetector.hasLoop(segmentTexts: texts) == true)
    }

    @Test
    func emptySegmentsBetweenRepeatsAreIgnored() {
        // Whisper's no-speech filter can drop intermediate segments. The remaining
        // non-empty segments still constitute a loop.
        let texts = [
            "thank you",
            "",
            "thank you",
            "   ",
            "thank you",
            "thank you",
            "thank you",
        ]
        #expect(LoopDetector.hasLoop(segmentTexts: texts) == true)
    }

    @Test
    func distinctSegmentsAreNotLoop() {
        let texts = [
            "the quick brown fox",
            "jumps over the lazy dog",
            "and runs into the forest",
            "where it finds a tree",
            "to rest under for the night",
        ]
        #expect(LoopDetector.hasLoop(segmentTexts: texts) == false)
    }

    @Test
    func shortRunFollowedByDifferentTextIsNotLoop() {
        // 4 consecutive (below threshold) then unique content.
        let texts = [
            "thank you",
            "thank you",
            "thank you",
            "thank you",
            "for listening",
            "and have a great day",
        ]
        #expect(LoopDetector.hasLoop(segmentTexts: texts) == false)
    }

    @Test
    func runResetsOnDifferentText() {
        // 3 identical, then different, then 3 identical — no run reaches 5.
        let texts = [
            "alpha",
            "alpha",
            "alpha",
            "beta",
            "alpha",
            "alpha",
            "alpha",
        ]
        #expect(LoopDetector.hasLoop(segmentTexts: texts) == false)
    }
}
