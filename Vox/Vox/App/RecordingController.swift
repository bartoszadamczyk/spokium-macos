import Foundation
import KeyboardShortcuts
import OSLog

enum RecordingState: Equatable {
    case idle
    case recording
    case finishing
}

enum RecordingError: Equatable {
    case noModel
    case transcriptionFailed(String)
    case downloadFailed(String)
    case noAccessibility
}

@Observable
@MainActor
final class RecordingController {
    private(set) var state: RecordingState = .idle
    private(set) var lastError: RecordingError?

    private let recorder = AudioRecorder()
    private let logger = Logger(subsystem: "com.bartoszadamczyk.Vox", category: "Recording")
    private var transcriber: Transcriber?

    init() {
        KeyboardShortcuts.onKeyDown(for: .toggleRecording) { [weak self] in
            self?.toggle()
        }
    }

    func cleanup() async {
        await transcriber?.unload()
        transcriber = nil
    }

    func dismissError() {
        lastError = nil
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
        let manager = ModelManager()
        guard manager.selectedModelURL != nil else {
            lastError = .noModel
            return
        }

        let url = makeTempURL()
        do {
            try await recorder.start(to: url)
            state = .recording
            logger.info("Recording started")
        } catch {
            try? FileManager.default.removeItem(at: url)
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
            defer {
                try? FileManager.default.removeItem(at: url)
                state = .idle
            }
            await transcribe(url: url)
        }
    }

    private func transcribe(url: URL) async {
        let manager = ModelManager()
        guard let modelURL = manager.selectedModelURL else {
            lastError = .noModel
            return
        }

        if transcriber?.modelURL != modelURL {
            transcriber = nil
        }
        let transcriber = self.transcriber ?? Transcriber(modelURL: modelURL)
        self.transcriber = transcriber

        do {
            let prompt = dictionaryPrompt()
            let settings = transcriptionSettings()
            let result = try await transcriber.transcribe(audioURL: url, initialPrompt: prompt, settings: settings)
            logger.info("Transcribed: language=\(result.language, privacy: .public), chars=\(result.text.count)")

            guard !result.text.isEmpty else { return }
            let pasted = await Paster.paste(result.text)
            if !pasted {
                lastError = .noAccessibility
                Paster.requestAccessibilityPermission()
            }
        } catch {
            logger.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
            lastError = .transcriptionFailed(error.localizedDescription)
        }
    }

    private func transcriptionSettings() -> TranscriptionSettings {
        let defaults = UserDefaults.standard
        return TranscriptionSettings(
            language: defaults.string(forKey: "selectedLanguage") ?? "auto",
            paragraphSplitting: defaults.object(forKey: "paragraphSplitting") as? Bool ?? true,
            silenceThreshold: defaults.object(forKey: "silenceThreshold") as? Double ?? 1.5
        )
    }

    private func dictionaryPrompt() -> String? {
        let raw = UserDefaults.standard.string(forKey: "dictionaryEntries") ?? ""
        let entries = raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !entries.isEmpty else { return nil }
        return entries.joined(separator: ", ")
    }

    private func makeTempURL() -> URL {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-\(timestamp).caf")
    }
}
