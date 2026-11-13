import AppKit
import Testing

@testable import Spokium

@MainActor
struct PasterPrivacyTests {
    private let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private func withPrivateClipboard(_ on: Bool, _ body: () -> Void) {
        let saved = UserDefaults.standard.object(forKey: DefaultsKey.privateClipboard)
        defer { UserDefaults.standard.set(saved, forKey: DefaultsKey.privateClipboard) }
        AppDefaults.privateClipboard = on
        body()
    }

    @Test
    func privateTranscript_carriesHistoryOptOutMarkers() {
        let pb = NSPasteboard(name: NSPasteboard.Name("spokium-tests-\(UUID().uuidString)"))
        withPrivateClipboard(true) { Paster.writeTranscript("hello", to: pb) }
        #expect(pb.string(forType: .string) == "hello")
        #expect(pb.types?.contains(transient) == true)
        #expect(pb.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) == true)
    }

    @Test
    func privacyOff_writesPlainText() {
        let pb = NSPasteboard(name: NSPasteboard.Name("spokium-tests-\(UUID().uuidString)"))
        withPrivateClipboard(false) { Paster.writeTranscript("hello", to: pb) }
        #expect(pb.string(forType: .string) == "hello")
        #expect(pb.types?.contains(transient) != true)
    }
}
