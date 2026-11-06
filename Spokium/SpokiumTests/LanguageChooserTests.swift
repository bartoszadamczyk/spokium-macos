import Testing

@testable import Spokium

@MainActor
struct LanguageChooserTests {
    @Test
    func picksHighestProbabilityAmongAllowed() {
        let probs: [String: Float] = ["pl": 0.30, "en": 0.55]
        #expect(LanguageChooser.best(probabilities: probs, allowed: ["pl", "en"]) == "en")
    }

    @Test
    func ignoresLanguagesOutsideAllowedSet() {
        // "tr" would win globally but isn't something the user speaks.
        let probs: [String: Float] = ["pl": 0.20, "en": 0.10, "tr": 0.60]
        #expect(LanguageChooser.best(probabilities: probs, allowed: ["pl", "en"]) == "pl")
    }

    @Test
    func tieGoesToFirstAllowed() {
        let probs: [String: Float] = ["pl": 0.4, "en": 0.4]
        #expect(LanguageChooser.best(probabilities: probs, allowed: ["en", "pl"]) == "en")
    }

    @Test
    func unknownCodesAreSkipped() {
        let probs: [String: Float] = ["pl": 0.1]
        #expect(LanguageChooser.best(probabilities: probs, allowed: ["xx", "pl"]) == "pl")
    }

    @Test
    func noKnownCodes_returnsNil() {
        #expect(LanguageChooser.best(probabilities: [:], allowed: ["pl", "en"]) == nil)
    }

    @Test
    func dominant_picksLanguageWithMostText() {
        let chars = ["pl": 420, "en": 130]
        #expect(LanguageChooser.dominant(charactersByLanguage: chars, allowed: ["en", "pl"]) == "pl")
    }

    @Test
    func dominant_ignoresLanguagesOutsideAllowed() {
        let chars = ["tr": 900, "en": 20]
        #expect(LanguageChooser.dominant(charactersByLanguage: chars, allowed: ["pl", "en"]) == "en")
    }

    @Test
    func dominant_noHistory_returnsNil() {
        #expect(LanguageChooser.dominant(charactersByLanguage: [:], allowed: ["pl", "en"]) == nil)
        #expect(LanguageChooser.dominant(charactersByLanguage: ["pl": 0], allowed: ["pl"]) == nil)
    }
}

@MainActor
struct LanguageUsageStoreTests {
    @Test
    func merge_accumulatesPerLanguage() {
        var counts: [String: Int] = [:]
        counts = LanguageUsageStore.merge(into: counts, language: "pl", characters: 100)
        counts = LanguageUsageStore.merge(into: counts, language: "en", characters: 40)
        counts = LanguageUsageStore.merge(into: counts, language: "pl", characters: 60)
        #expect(counts == ["pl": 160, "en": 40])
    }

    @Test
    func merge_ignoresEmptyAndUnknown() {
        let counts = ["pl": 10]
        #expect(LanguageUsageStore.merge(into: counts, language: "en", characters: 0) == counts)
        #expect(LanguageUsageStore.merge(into: counts, language: "unknown", characters: 50) == counts)
        #expect(LanguageUsageStore.merge(into: counts, language: "", characters: 50) == counts)
    }

    @Test
    func shares_areSortedAndSumToOne() {
        let shares = LanguageUsageStore.shares(["en": 25, "pl": 75])
        #expect(shares.map(\.code) == ["pl", "en"])
        #expect(abs(shares.map(\.fraction).reduce(0, +) - 1) < 1e-9)
        #expect(abs(shares[0].fraction - 0.75) < 1e-9)
    }

    @Test
    func shares_emptyWhenNoData() {
        #expect(LanguageUsageStore.shares([:]).isEmpty)
        #expect(LanguageUsageStore.shares(["pl": 0]).isEmpty)
    }
}
