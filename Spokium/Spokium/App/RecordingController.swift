import AppKit
import Foundation
import KeyboardShortcuts
import OSLog

enum RecordingState: Equatable {
    case idle
    case starting
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

    var menuMessage: String {
        switch self {
        case .noModel: "No Whisper model selected"
        case .microphoneDenied: "Microphone access denied"
        case .recordingFailed: "Recording failed"
        case .transcriptionFailed: "Transcription failed"
        case .downloadFailed: "Model download failed"
        case .noAccessibility: "Paste blocked — Accessibility permission needed"
        }
    }
}

enum CompletionFeedback: Equatable {
    case pasted
    case copied
    case empty
}

@Observable
@MainActor
final class RecordingController {
    private(set) var state: RecordingState = .idle
    private(set) var lastError: RecordingError?
    private(set) var persistentError: RecordingError?
    private(set) var lastCompletion: CompletionFeedback?
    private(set) var inputLevel: Float = 0

    private let recorder = AudioRecorder()
    private let logger = Logger(subsystem: "com.bartoszadamczyk.Spokium", category: "Recording")
    private var transcriber: Transcriber?
    private var recordingStartedAt: ContinuousClock.Instant?
    private var transcriptionTask: Task<Void, Never>?
    private var levelTimer: Timer?
    private var escapeMonitor: Any?
    private var autoStopTask: Task<Void, Never>?
    private var currentRecordingURL: URL?
    private var pendingStartCancel = false

    init() {
        KeyboardShortcuts.onKeyDown(for: .toggleRecording) { [weak self] in
            self?.handleKeyDown()
        }
        KeyboardShortcuts.onKeyUp(for: .toggleRecording) { [weak self] in
            self?.handleKeyUp()
        }
        recorder.onConfigurationChange = { [weak self] in
            self?.handleAudioConfigurationChange()
        }
    }

    private func handleAudioConfigurationChange() {
        guard case .recording = state else { return }
        logger.error("Audio configuration changed during recording — aborting")
        stopLevelMonitoring()
        stopEscapeMonitor()
        autoStopTask?.cancel()
        autoStopTask = nil
        _ = recorder.stop()
        clearRecordingFile()
        state = .idle
        reportError(.recordingFailed("Audio input changed during recording."))
    }

    private func clearRecordingFile() {
        if let url = currentRecordingURL {
            try? FileManager.default.removeItem(at: url)
            currentRecordingURL = nil
        }
    }

    private var isPushToRecord: Bool {
        UserDefaults.standard.bool(forKey: "pushToRecord")
    }

    private func handleKeyDown() {
        if isPushToRecord {
            if case .idle = state {
                state = .starting
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

    func dismissPersistentError() {
        persistentError = nil
    }

    func clearCompletion() {
        lastCompletion = nil
    }

    private func reportError(_ error: RecordingError) {
        lastError = error
        persistentError = error
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
            state = .starting
            Task { await start() }
        case .starting:
            break
        case .recording:
            stop()
        case .finishing:
            break
        }
    }

    func cancel() {
        switch state {
        case .starting:
            pendingStartCancel = true
            logger.info("Recording start cancellation requested")
        case .recording:
            stopLevelMonitoring()
            stopEscapeMonitor()
            autoStopTask?.cancel()
            autoStopTask = nil
            _ = recorder.stop()
            clearRecordingFile()
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
        lastError = nil
        persistentError = nil
        pendingStartCancel = false

        let manager = ModelManager()
        guard manager.selectedModelURL != nil else {
            state = .idle
            reportError(.noModel)
            return
        }

        let url = makeTempURL()
        currentRecordingURL = url
        do {
            try await recorder.start(to: url)
            if pendingStartCancel {
                _ = recorder.stop()
                clearRecordingFile()
                state = .idle
                logger.info("Recording start cancelled")
                return
            }
            recordingStartedAt = .now
            state = .recording
            startLevelMonitoring()
            startEscapeMonitor()
            startAutoStopTask()
            RecordingSounds.playStart()
            logger.info("Recording started")
        } catch AudioRecorderError.microphoneDenied {
            clearRecordingFile()
            state = .idle
            reportError(.microphoneDenied)
        } catch {
            clearRecordingFile()
            state = .idle
            logger.error("Recording failed to start: \(error.localizedDescription, privacy: .public)")
            reportError(.recordingFailed(error.localizedDescription))
        }
    }

    private func stop() {
        state = .finishing
        stopLevelMonitoring()
        autoStopTask?.cancel()
        autoStopTask = nil
        guard let url = recorder.stop() else {
            reportError(.recordingFailed("Audio recording failed to save."))
            clearRecordingFile()
            state = .idle
            stopEscapeMonitor()
            return
        }

        transcriptionTask = Task {
            defer {
                clearRecordingFile()
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
            reportError(.noModel)
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
            guard !finalText.isEmpty else {
                lastCompletion = .empty
                RecordingSounds.playEmpty()
                return
            }
            switch await Paster.paste(finalText) {
            case .pasted:
                lastCompletion = .pasted
                RecordingSounds.playPaste()
            case .copied:
                lastCompletion = .copied
                RecordingSounds.playPaste()
            case .failedNoAccessibility:
                reportError(.noAccessibility)
                Paster.requestAccessibilityPermission()
            }
        } catch TranscriberError.cancelled {
            logger.info("Transcription aborted")
        } catch {
            logger.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
            reportError(.transcriptionFailed(error.localizedDescription))
        }
    }

    private func transcriptionSettings() -> TranscriptionSettings {
        let defaults = UserDefaults.standard
        return TranscriptionSettings(
            language: defaults.string(forKey: "selectedLanguage") ?? "auto",
            paragraphSplitting: defaults.object(forKey: "paragraphSplitting") as? Bool ?? true,
            minSilenceDuration: defaults.object(forKey: "silenceThreshold") as? Double ?? 1.5
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
        let minutes = UserDefaults.standard.object(forKey: "maxRecordingMinutes") as? Double ?? 10
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
