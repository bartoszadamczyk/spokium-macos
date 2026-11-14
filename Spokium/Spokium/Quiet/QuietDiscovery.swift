import Foundation
import Network
import OSLog

// Finds devices announcing `_spokium-quiet._tcp` — the generic "quiet me while you
// listen" contract. TXT: `id` (stable identity), `name` (shown), `path` (the endpoint:
// POST quietens ~30 s, DELETE restores). Found devices are merged into
// QuietEndpointStore by id, keeping the last address so recording never waits for
// discovery and a device that's offline keeps its tick.
//
// Browsing makes macOS ask for local-network access, so it only runs while Settings →
// Integrations is open, and briefly at recording start when a discovered device is
// ticked (to refresh its address).
final class QuietDiscovery {
    static let serviceType = "_spokium-quiet._tcp"
    static let shared = QuietDiscovery()

    struct Found: Equatable {
        let id: String
        let name: String
        let url: URL
    }

    // Ids seen during the current browse (Settings shows the rest as "not found").
    private(set) var online: Set<String> = []
    var onChange: (() -> Void)?

    private var browser: NWBrowser?
    private var users = 0
    private var resolving: [String: NWConnection] = [:]
    private let logger = Logger(subsystem: "com.spokium.mac", category: "Quiet")

    func start() {
        users += 1
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let sightings = results.compactMap(Sighting.init)
            Task { @MainActor in self?.update(sightings) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        browser?.cancel()
        browser = nil
        resolving.values.forEach { $0.cancel() }
        resolving = [:]
    }

    // A short browse to refresh addresses, e.g. when a recording starts.
    func refresh(for duration: Duration = .seconds(5)) {
        start()
        Task { [weak self] in
            try? await Task.sleep(for: duration)
            self?.stop()
        }
    }

    private nonisolated struct Sighting: @unchecked Sendable {
        let endpoint: NWEndpoint
        let id: String
        let name: String
        let path: String

        init?(_ result: NWBrowser.Result) {
            guard case let .service(serviceName, _, _, _) = result.endpoint else { return nil }
            var txt: NWTXTRecord?
            if case let .bonjour(record) = result.metadata { txt = record }
            endpoint = result.endpoint
            id = txt?["id"].flatMap { $0.isEmpty ? nil : $0 } ?? serviceName
            name = txt?["name"].flatMap { $0.isEmpty ? nil : $0 } ?? serviceName
            let raw = txt?["path"] ?? "/"
            path = raw.hasPrefix("/") ? raw : "/" + raw
        }
    }

    private func update(_ sightings: [Sighting]) {
        online = Set(sightings.map(\.id))
        for sighting in sightings where resolving[sighting.id] == nil {
            resolving[sighting.id] = resolve(sighting)
        }
        onChange?()
    }

    // A connection is how a Bonjour service's address is learnt: opened, read,
    // closed. IPv4, so the address fits a plain URL.
    private func resolve(_ sighting: Sighting) -> NWConnection {
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let connection = NWConnection(to: sighting.endpoint, using: parameters)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            let remote = connection?.currentPath?.remoteEndpoint
            switch state {
            case .ready, .failed, .waiting:
                connection?.cancel()
                Task { @MainActor in self?.resolved(sighting, remote: state == .ready ? remote : nil) }
            default:
                break
            }
        }
        connection.start(queue: .main)
        return connection
    }

    private func resolved(_ sighting: Sighting, remote: NWEndpoint?) {
        resolving[sighting.id] = nil
        guard case let .hostPort(host, port) = remote else { return }
        let address = "\(host)".split(separator: "%").first.map(String.init) ?? "\(host)"
        guard let url = URL(string: "http://\(address):\(port.rawValue)\(sighting.path)") else { return }
        QuietEndpointStore.merge(Found(id: sighting.id, name: sighting.name, url: url))
        onChange?()
    }
}
