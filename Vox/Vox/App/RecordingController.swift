import AppKit
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
    case microphoneDenied
    case recordingFailed(String)
    case transcriptionFailed(String)
    case downloadFailed(String)
    case noAccessibility
}

@Observable
@MainActor
final class RecordingController {
    private(set) var state: RecordingState = .idle
    private(set) var lastError: RecordingError?
    private(set) var inputLevel: Float = 0

    private let recorder = AudioRecorder()
    private let logger = Logger(subsystem: "com.bartoszadamczyk.Vox", category: "Recording")
    private var transcriber: Transcriber?
    private var recordingStartedAt: ContinuousClock.Instant?
    private var transcriptionTask: Task<Void, Never>?
    private var levelTimer: Timer?
    private var escapeMonitor: Any?
    private var autoStopTask: Task<Void, Never>?

    init() {
        KeyboardShortcuts.onKeyDown(for: .toggleRecording) { [weak self] in
            self?.handleKeyDown()
        }
        KeyboardShortcuts.onKeyUp(for: .toggleRecording) { [weak self] in
            self?.handleKeyUp()
        }
    }

    private var isPushToRecord: Bool {
        UserDefaults.standard.bool(forKey: "pushToRecord")
    }

    private func handleKeyDown() {
        if isPushToRecord {
            if case .idle = state {
                Task { await start() }
            }
        } else {
            toggle()
        }
    }

    private func handleKeyUp() {
        guard isPushToRecord else { return }
        if case .recording = state {
            stop()
        }
    }

    func cleanup() async {
        stopEscapeMonitor()
        transcriptionTask?.cancel()
        transcriptionTask = nil
        await transcriber?.unload()
        transcriber = nil
    }

    func dismissError() {
        lastError = nil
    }

    func countDictionaryTokens(_ text: String) async -> Int? {
        let manager = ModelManager()
        guard let modelURL = manager.selectedModelURL else { return nil }
        if transcriber?.modelURL != modelURL {
            transcriber = nil
        }
        let transcriber = self.transcriber ?? Transcriber(modelURL: modelURL)
        self.transcriber = transcriber
        return try? await transcriber.tokenCount(for: text)
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

    func cancel() {
        switch state {
        case .recording:
            stopLevelMonitoring()
            stopEscapeMonitor()
            autoStopTask?.cancel()
            autoStopTask = nil
            _ = recorder.stop()
            state = .idle
            logger.info("Recording cancelled")
        case .finishing:
            transcriber?.abort()
            transcriptionTask?.cancel()
            logger.info("Transcription cancelled")
        case .idle:
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
            recordingStartedAt = .now
            state = .recording
            startLevelMonitoring()
            startEscapeMonitor()
            startAutoStopTask()
            logger.info("Recording started")
        } catch AudioRecorderError.microphoneDenied {
            try? FileManager.default.removeItem(at: url)
            lastError = .microphoneDenied
        } catch {
            try? FileManager.default.removeItem(at: url)
            logger.error("Recording failed to start: \(error.localizedDescription, privacy: .public)")
            lastError = .recordingFailed(error.localizedDescription)
        }
    }

    private func stop() {
        state = .finishing
        stopLevelMonitoring()
        autoStopTask?.cancel()
        autoStopTask = nil
        guard let url = recorder.stop() else {
            lastError = .recordingFailed("Audio recording failed to save.")
            state = .idle
            stopEscapeMonitor()
            return
        }

        transcriptionTask = Task {
            defer {
                try? FileManager.default.removeItem(at: url)
                state = .idle
                stopEscapeMonitor()
                transcriptionTask = nil
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

        let recordingDuration = recordingStartedAt.map { ContinuousClock.now - $0 } ?? .zero

        do {
            let prompt = dictionaryPrompt()
            let settings = transcriptionSettings()
            let transcriptionStart = ContinuousClock.now
            let result = try await transcriber.transcribe(audioURL: url, initialPrompt: prompt, settings: settings)
            let transcriptionDuration = ContinuousClock.now - transcriptionStart
            let modelName = modelURL.deletingPathExtension().lastPathComponent
            logger.info("Transcribed: model=\(modelName, privacy: .public), language=\(result.language, privacy: .public), chars=\(result.text.count), recording=\(recordingDuration, privacy: .public), transcription=\(transcriptionDuration, privacy: .public)")

            if Task.isCancelled {
                logger.info("Transcription discarded (cancelled)")
                return
            }
            let finalText = SnippetStore.apply(to: result.text)
            guard !finalText.isEmpty else { return }
            let pasted = await Paster.paste(finalText)
            if !pasted {
                lastError = .noAccessibility
                Paster.requestAccessibilityPermission()
            }
        } catch TranscriberError.cancelled {
            logger.info("Transcription aborted")
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

    private func startLevelMonitoring() {
        levelTimer?.invalidate()
        let smoothing: Float = 0.3
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let raw = self.recorder.currentLevel
                self.inputLevel = self.inputLevel * (1 - smoothing) + raw * smoothing
            }
        }
    }

    private func stopLevelMonitoring() {
        levelTimer?.invalidate()
        levelTimer = nil
        inputLevel = 0
    }

    private func startAutoStopTask() {
        autoStopTask?.cancel()
        let minutes = UserDefaults.standard.object(forKey: "maxRecordingMinutes") as? Double ?? 5
        guard minutes > 0 else { return }
        let nanoseconds = UInt64(minutes * 60 * 1_000_000_000)
        autoStopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, case .recording = self.state else { return }
                self.logger.info("Auto-stopping recording (time limit reached)")
                self.stop()
            }
        }
    }

    private func startEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor [weak self] in
                self?.cancel()
            }
        }
    }

    private func stopEscapeMonitor() {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
    }

    private func makeTempURL() -> URL {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-\(timestamp).caf")
    }
}
