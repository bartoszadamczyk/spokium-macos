import Testing

@testable import Spokium

@MainActor
struct QuietEndpointTests {
    @Test
    func httpAndHttpsWithHost_areValid() {
        #expect(QuietEndpoint(url: "http://radio.local/quiet").validURL != nil)
        #expect(QuietEndpoint(url: " https://192.168.1.20:8080/mute ").validURL != nil)
    }

    @Test
    func otherSchemesOrMissingHost_areRejected() {
        #expect(QuietEndpoint(url: "").validURL == nil)
        #expect(QuietEndpoint(url: "radio.local/quiet").validURL == nil)
        #expect(QuietEndpoint(url: "ftp://radio.local").validURL == nil)
        #expect(QuietEndpoint(url: "file:///etc/hosts").validURL == nil)
    }
}
