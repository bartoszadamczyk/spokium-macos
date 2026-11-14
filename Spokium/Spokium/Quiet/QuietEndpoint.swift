import Foundation

// A user-configured device to quiet while recording, e.g. a home-made radio. Contract:
// POST mutes it for ~30 s (each POST restarts that timer), DELETE un-mutes. No body.
// Any number can be enabled at once.
struct QuietEndpoint: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var url: String
    // nil only in data saved before multi-select (1.5.3 and earlier); see the store.
    var isEnabled: Bool?
    // The device's own id when found via `_spokium-quiet._tcp` (nil = typed in). Its
    // name and URL then come from discovery; the URL is the last address seen.
    var discoveredID: String?

    init(id: UUID = UUID(), name: String = "", url: String = "", isEnabled: Bool = true, discoveredID: String? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.isEnabled = isEnabled
        self.discoveredID = discoveredID
    }

    var isDiscovered: Bool { discoveredID != nil }

    var enabled: Bool { isEnabled ?? false }

    var displayName: String { name.isEmpty ? url : name }

    var validURL: URL? {
        guard let url = URL(string: url.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host() != nil else { return nil }
        return url
    }
}

extension Notification.Name {
    static let quietEndpointsChanged = Notification.Name("SpokiumQuietEndpointsChanged")
}

enum QuietEndpointStore {
    static func load() -> [QuietEndpoint] {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.quietEndpoints),
              var endpoints = try? JSONDecoder().decode([QuietEndpoint].self, from: data) else { return [] }
        // Before multi-select a single endpoint was chosen in selectedQuietEndpoint.
        if endpoints.contains(where: { $0.isEnabled == nil }) {
            let legacy = AppDefaults.selectedQuietEndpoint
            for index in endpoints.indices where endpoints[index].isEnabled == nil {
                endpoints[index].isEnabled = endpoints[index].id.uuidString == legacy
            }
            save(endpoints)
        }
        return endpoints
    }

    static func save(_ endpoints: [QuietEndpoint]) {
        guard let data = try? JSONEncoder().encode(endpoints) else { return }
        UserDefaults.standard.set(data, forKey: DefaultsKey.quietEndpoints)
    }

    static var enabled: [QuietEndpoint] {
        load().filter { $0.enabled && $0.validURL != nil }
    }

    // A device found on the network: refresh its name and address, or add it unticked.
    static func merge(_ found: QuietDiscovery.Found) {
        var endpoints = load()
        if let index = endpoints.firstIndex(where: { $0.discoveredID == found.id }) {
            guard endpoints[index].name != found.name || endpoints[index].url != found.url.absoluteString else { return }
            endpoints[index].name = found.name
            endpoints[index].url = found.url.absoluteString
        } else {
            endpoints.append(QuietEndpoint(name: found.name, url: found.url.absoluteString, isEnabled: false, discoveredID: found.id))
        }
        save(endpoints)
        NotificationCenter.default.post(name: .quietEndpointsChanged, object: nil)
    }

    static func setEnabled(_ on: Bool, id: QuietEndpoint.ID) {
        var endpoints = load()
        guard let index = endpoints.firstIndex(where: { $0.id == id }) else { return }
        endpoints[index].isEnabled = on
        save(endpoints)
    }
}
