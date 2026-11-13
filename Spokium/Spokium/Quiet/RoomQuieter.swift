import Foundation
import OSLog

// Keeps every enabled QuietEndpoint muted while a recording runs: POST at start, POST
// again every `refresh` to extend its ~30 s mute, DELETE at stop. Requests are
// fire-and-forget with a short timeout and never hold up recording. If the app dies
// mid-recording each endpoint's own timeout un-mutes it.
//
// The only network use besides Hugging Face model downloads: user-entered URLs, no body,
// nothing about the recording is sent.
final class RoomQuieter {
    static let refresh: Duration = .seconds(20)

    private var active: [QuietEndpoint.ID: QuietEndpoint] = [:]
    private var refreshTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.spokium.mac", category: "Quiet")

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 2
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    func begin() {
        update()
        guard refreshTask == nil, !active.isEmpty else { return }
        refreshTask = Task { [weak self] in
            while true {
                try? await Task.sleep(for: Self.refresh)
                guard !Task.isCancelled, let self else { return }
                for endpoint in self.active.values { self.send("POST", to: endpoint) }
            }
        }
    }

    // Brings the muted set in line with the enabled endpoints without touching the ones
    // that stay: ticking a device mid-recording mutes just it, unticking un-mutes just it.
    func update() {
        let wanted = Dictionary(uniqueKeysWithValues: QuietEndpointStore.enabled.map { ($0.id, $0) })
        for (id, endpoint) in active where wanted[id] == nil {
            send("DELETE", to: endpoint)
        }
        for (id, endpoint) in wanted where active[id] == nil {
            send("POST", to: endpoint)
        }
        active = wanted
    }

    func end() {
        refreshTask?.cancel()
        refreshTask = nil
        for endpoint in active.values { send("DELETE", to: endpoint) }
        active = [:]
    }

    private func send(_ method: String, to endpoint: QuietEndpoint) {
        guard let url = endpoint.validURL else { return }
        var request = URLRequest(url: url)
        request.httpMethod = method
        let logger = logger
        let name = endpoint.displayName
        Task.detached {
            do {
                let (_, response) = try await Self.session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(status) {
                    logger.info("Quiet \(method, privacy: .public) \(name, privacy: .public): \(status)")
                } else {
                    logger.notice("Quiet \(method, privacy: .public) \(name, privacy: .public): HTTP \(status)")
                }
            } catch {
                logger.notice("Quiet \(method, privacy: .public) \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
