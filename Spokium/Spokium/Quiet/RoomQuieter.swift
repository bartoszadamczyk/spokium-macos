import Foundation
import OSLog

// Keeps the selected QuietEndpoint muted while a recording runs: POST at start, POST
// again every `refresh` to extend its ~30 s mute, DELETE at stop. Requests are
// fire-and-forget with a short timeout and never hold up recording. If the app dies
// mid-recording the endpoint's own timeout un-mutes it.
//
// The only network use besides Hugging Face model downloads: user-entered URLs, no body,
// nothing about the recording is sent.
final class RoomQuieter {
    static let refresh: Duration = .seconds(20)

    private var active: QuietEndpoint?
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
        end()
        guard let endpoint = QuietEndpointStore.selected, let url = endpoint.validURL else { return }
        active = endpoint
        send("POST", to: url, name: endpoint.name)
        refreshTask = Task { [weak self] in
            while true {
                try? await Task.sleep(for: Self.refresh)
                guard !Task.isCancelled, let self else { return }
                self.send("POST", to: url, name: endpoint.name)
            }
        }
    }

    func end() {
        refreshTask?.cancel()
        refreshTask = nil
        guard let endpoint = active else { return }
        active = nil
        if let url = endpoint.validURL {
            send("DELETE", to: url, name: endpoint.name)
        }
    }

    private func send(_ method: String, to url: URL, name: String) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        let logger = logger
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
