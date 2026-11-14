import Foundation
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

@MainActor
struct QuietEndpointMultiSelectTests {
    @Test
    func legacySingleSelection_becomesTheOneTickedDevice() throws {
        let saved = (UserDefaults.standard.data(forKey: DefaultsKey.quietEndpoints),
                     UserDefaults.standard.string(forKey: DefaultsKey.selectedQuietEndpoint))
        defer {
            UserDefaults.standard.set(saved.0, forKey: DefaultsKey.quietEndpoints)
            UserDefaults.standard.set(saved.1, forKey: DefaultsKey.selectedQuietEndpoint)
        }
        let kitchen = UUID(), office = UUID()
        // 1.5.3 format: no isEnabled; the chosen one lived in selectedQuietEndpoint.
        let legacy = """
        [{"id":"\(kitchen.uuidString)","name":"Kitchen","url":"http://kitchen.local/quiet"},
         {"id":"\(office.uuidString)","name":"Office","url":"http://office.local/quiet"}]
        """
        UserDefaults.standard.set(Data(legacy.utf8), forKey: DefaultsKey.quietEndpoints)
        UserDefaults.standard.set(office.uuidString, forKey: DefaultsKey.selectedQuietEndpoint)

        let loaded = QuietEndpointStore.load()
        #expect(loaded.first { $0.id == kitchen }?.enabled == false)
        #expect(loaded.first { $0.id == office }?.enabled == true)

        QuietEndpointStore.setEnabled(true, id: kitchen)
        #expect(Set(QuietEndpointStore.enabled.map(\.id)) == [kitchen, office])
    }
}

@MainActor
struct QuietDiscoveryMergeTests {
    private func withEmptyStore(_ body: () throws -> Void) rethrows {
        let saved = UserDefaults.standard.data(forKey: DefaultsKey.quietEndpoints)
        defer { UserDefaults.standard.set(saved, forKey: DefaultsKey.quietEndpoints) }
        UserDefaults.standard.removeObject(forKey: DefaultsKey.quietEndpoints)
        try body()
    }

    @Test
    func foundDevice_isAddedUnticked_thenUpdatedInPlaceByID() throws {
        try withEmptyStore {
            let first = try #require(URL(string: "http://192.168.1.20:80/api/duck"))
            QuietEndpointStore.merge(.init(id: "dev-1", name: "Kitchen", url: first))
            var all = QuietEndpointStore.load()
            #expect(all.count == 1 && all[0].isDiscovered && !all[0].enabled)

            QuietEndpointStore.setEnabled(true, id: all[0].id)
            // New address and a renamed room: same entry, tick kept.
            let moved = try #require(URL(string: "http://192.168.1.31:80/api/duck"))
            QuietEndpointStore.merge(.init(id: "dev-1", name: "Kitchen (new)", url: moved))
            all = QuietEndpointStore.load()
            #expect(all.count == 1)
            #expect(all[0].name == "Kitchen (new)" && all[0].url == moved.absoluteString && all[0].enabled)
        }
    }
}
