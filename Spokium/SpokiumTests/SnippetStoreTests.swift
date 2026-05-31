import Testing
@testable import Spokium

@MainActor
struct SnippetStoreTests {
    private func snippet(_ trigger: String, _ replacement: String) -> Snippet {
        Snippet(trigger: trigger, replacement: replacement)
    }

    @Test func emptySnippets_leavesTextUnchanged() {
        let result = SnippetStore.apply([], to: "hello world")
        #expect(result == "hello world")
    }

    @Test func wholeWordMatch_isReplaced() {
        let result = SnippetStore.apply([snippet("foo", "bar")], to: "the foo here")
        #expect(result == "the bar here")
    }

    @Test func substringWithinWord_isNotReplaced() {
        let result = SnippetStore.apply([snippet("foo", "bar")], to: "foobar")
        #expect(result == "foobar")
    }

    @Test func caseInsensitiveMatch_isReplaced() {
        let result = SnippetStore.apply([snippet("foo", "BAR")], to: "FOO Foo foo")
        #expect(result == "BAR BAR BAR")
    }

    @Test func multiWordTrigger_isReplaced() {
        let result = SnippetStore.apply(
            [snippet("calendar link", "https://cal.example.com/me")],
            to: "send the calendar link please"
        )
        #expect(result == "send the https://cal.example.com/me please")
    }

    @Test func emptyTrigger_isSkipped() {
        let result = SnippetStore.apply([snippet("", "anything")], to: "hello world")
        #expect(result == "hello world")
    }

    @Test func whitespaceOnlyTrigger_isSkipped() {
        let result = SnippetStore.apply([snippet("   ", "anything")], to: "hello world")
        #expect(result == "hello world")
    }

    @Test func triggerWithSurroundingWhitespace_isTrimmed() {
        let result = SnippetStore.apply([snippet("  foo  ", "bar")], to: "the foo here")
        #expect(result == "the bar here")
    }

    @Test func punctuationNeighbor_stillMatches() {
        let result = SnippetStore.apply([snippet("foo", "bar")], to: "foo, foo. foo!")
        #expect(result == "bar, bar. bar!")
    }

    @Test func replacementWithDollarSign_isTreatedAsLiteral() {
        // $1 would be a regex backreference if the template were not escaped.
        let result = SnippetStore.apply([snippet("price", "$1.99")], to: "the price today")
        #expect(result == "the $1.99 today")
    }

    @Test func replacementWithBackslash_isTreatedAsLiteral() {
        let result = SnippetStore.apply([snippet("path", "C:\\Users")], to: "the path here")
        #expect(result == "the C:\\Users here")
    }

    @Test func multipleSnippets_appliedInOrder() {
        let result = SnippetStore.apply(
            [snippet("a", "x"), snippet("b", "y")],
            to: "a and b"
        )
        #expect(result == "x and y")
    }

    // MARK: - Unicode triggers (these work — `\b` uses Unicode word boundaries
    // in NSRegularExpression, and accented + CJK characters are word chars).

    @Test func unicodeAccentedTrigger_matches() {
        let result = SnippetStore.apply(
            [snippet("café", "coffee shop")],
            to: "meet at café tomorrow"
        )
        #expect(result == "meet at coffee shop tomorrow")
    }

    @Test func unicodeCJKTrigger_matches() {
        let result = SnippetStore.apply(
            [snippet("日本語", "Japanese")],
            to: "I learn 日本語 daily"
        )
        #expect(result == "I learn Japanese daily")
    }

    // MARK: - Embedded punctuation triggers — match when both ends are word chars.

    @Test func dottedIdentifierTrigger_matches_whenBothEndsAreWordChars() {
        let result = SnippetStore.apply(
            [snippet("node.js", "Node.js")],
            to: "use node.js daily"
        )
        #expect(result == "use Node.js daily")
    }

    @Test func versionStyleTrigger_matches() {
        let result = SnippetStore.apply(
            [snippet("v1.2", "version 1.2")],
            to: "release v1.2 now"
        )
        #expect(result == "release version 1.2 now")
    }

    @Test func emailLikeTrigger_matches() {
        let result = SnippetStore.apply(
            [snippet("foo@bar.com", "<email>")],
            to: "send foo@bar.com please"
        )
        #expect(result == "send <email> please")
    }

    // MARK: - Triggers with leading or trailing non-word chars
    // (these used to fail under `\b` matching; now work via lookarounds).

    @Test func cppTrigger_matches() {
        let result = SnippetStore.apply(
            [snippet("C++", "the language")],
            to: "I love C++ programming"
        )
        #expect(result == "I love the language programming")
    }

    @Test func triggerEndingWithDot_matches() {
        let result = SnippetStore.apply(
            [snippet("Mr.", "Mister")],
            to: "see Mr. Smith"
        )
        #expect(result == "see Mister Smith")
    }

    @Test func hashtagTrigger_matches() {
        let result = SnippetStore.apply(
            [snippet("#hello", "world")],
            to: "tweet #hello today"
        )
        #expect(result == "tweet world today")
    }

    @Test func triggerAtStartOfString_matches() {
        let result = SnippetStore.apply(
            [snippet("hello", "hi")],
            to: "hello world"
        )
        #expect(result == "hi world")
    }

    @Test func triggerAtEndOfString_matches() {
        let result = SnippetStore.apply(
            [snippet("world", "earth")],
            to: "hello world"
        )
        #expect(result == "hello earth")
    }
}
