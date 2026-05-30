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
}
