import Foundation
import KeyboardShortcuts
import OSLog

enum RecordingState: Equatable {
    case idle
    case recording
    case finishing
}

@Observable
@MainActor
final class RecordingController {
    private(set) var state: RecordingState = .idle

    private let recorder = AudioRecorder()
    private let logger = Logger(subsystem: "com.bartoszadamczyk.Vox", category: "Recording")
    private var transcriber: Transcriber?

    init() {
        KeyboardShortcuts.onKeyDown(for: .toggleRecording) { [weak self] in
            self?.toggle()
        }
    }

    func toggle() {
        switch state {
        case .idle:
            Task { await start() }
        case .recording:
            stop()
        case .finishing:
            break
        }
    }

    private func start() async {
        let url = makeTempURL()
        do {
            try await recorder.start(to: url)
            state = .recording
            logger.info("Recording started")
        } catch {
            logger.error("Recording failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func stop() {
        state = .finishing
        guard let url = recorder.stop() else {
            state = .idle
            return
        }

        Task {
            await transcribe(url: url)
            try? FileManager.default.removeItem(at: url)
            state = .idle
        }
    }

    private func transcribe(url: URL) async {
        let manager = ModelManager()
        guard let modelURL = manager.selectedModelURL else {
            logger.error(
                "No whisper model found. Drop a ggml-*.bin into: \(ModelLocator.modelsDirectory.path, privacy: .public)"
            )
            return
        }

        if transcriber?.modelURL != modelURL {
            transcriber = nil
        }
        let transcriber = self.transcriber ?? Transcriber(modelURL: modelURL)
        self.transcriber = transcriber

        do {
            let result = try await transcriber.transcribe(audioURL: url)
            logger.info("[\(result.language)] \(result.text, privacy: .public)")
        } catch {
            logger.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func makeTempURL() -> URL {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-\(timestamp).caf")
    }
}
