import Foundation

// A user-configured device to quiet while recording, e.g. a home-made radio. Contract:
// POST mutes it for ~30 s (each POST restarts that timer), DELETE un-mutes. No body.
struct QuietEndpoint: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var url: String

    init(id: UUID = UUID(), name: String = "", url: String = "") {
        self.id = id
        self.name = name
        self.url = url
    }

    var validURL: URL? {
        guard let url = URL(string: url.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host() != nil else { return nil }
        return url
    }
}

enum QuietEndpointStore {
    static func load() -> [QuietEndpoint] {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.quietEndpoints),
              let endpoints = try? JSONDecoder().decode([QuietEndpoint].self, from: data) else { return [] }
        return endpoints
    }

    static func save(_ endpoints: [QuietEndpoint]) {
        guard let data = try? JSONEncoder().encode(endpoints) else { return }
        UserDefaults.standard.set(data, forKey: DefaultsKey.quietEndpoints)
    }

    static var selected: QuietEndpoint? {
        let id = AppDefaults.selectedQuietEndpoint
        guard !id.isEmpty else { return nil }
        return load().first { $0.id.uuidString == id }
    }
}
