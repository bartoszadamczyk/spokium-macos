import Testing
@testable import Spokium

@MainActor
struct DictionaryPromptBuilderTests {
    @Test func emptyString_returnsNil() {
        #expect(DictionaryPromptBuilder.prompt(from: "") == nil)
    }

    @Test func whitespaceOnly_returnsNil() {
        #expect(DictionaryPromptBuilder.prompt(from: "   \n  \t  \n") == nil)
    }

    @Test func singleEntry_returnsThatEntry() {
        #expect(DictionaryPromptBuilder.prompt(from: "Anthropic") == "Anthropic")
    }

    @Test func multipleEntries_joinedWithCommaSpace() {
        #expect(DictionaryPromptBuilder.prompt(from: "Anthropic\nClaude") == "Anthropic, Claude")
    }

    @Test func entriesHaveSurroundingWhitespaceTrimmed() {
        #expect(DictionaryPromptBuilder.prompt(from: "  Anthropic  \n  Claude  ") == "Anthropic, Claude")
    }

    @Test func emptyLines_areFilteredOut() {
        #expect(DictionaryPromptBuilder.prompt(from: "Anthropic\n\n\nClaude\n") == "Anthropic, Claude")
    }

    @Test func tabsAndSpaces_inEntries_arePreserved() {
        // Internal whitespace inside an entry is kept; only leading/trailing is trimmed.
        #expect(DictionaryPromptBuilder.prompt(from: "Claude Sonnet 4.6") == "Claude Sonnet 4.6")
    }
}
