import AVFoundation
import Foundation
import OSLog

extension RecordingController {
    func start() async {
        lastError = nil
        persistentError = nil
        pendingStartCancel = false
        sessionTexts = []
        pendingSegmentsAudioSeconds = 0
        currentSegmentStartedAt = nil
        sessionStartedAt = nil
        pendingAudioSegments = []

        let manager = ModelManager()
        guard manager.selectedModelURL != nil else {
            state = .idle
            reportError(.noModel)
            return
        }

        await startSegment(playSound: true)
    }

    // Starts a new recording segment within the current session (transcription still running)
    func continueSession() {
        let manager = ModelManager()
        guard manager.selectedModelURL != nil else {
            reportError(.noModel)
            return
        }
        pendingStartCancel = false
        pendingAudioSegments = []
        state = .starting
        Task { await startSegment(playSound: false) }
    }

    func startSegment(playSound: Bool) async {
        let url = makeTempURL()
        currentRecordingURL = url
        do {
            try await recorder.start(to: url)
            if pendingStartCancel {
                _ = recorder.stop()
                clearCurrentSegment()
                returnFromRecording()
                logger.info("Recording start cancelled")
                return
            }
            if sessionStartedAt == nil { sessionStartedAt = .now }
            state = .recording
            currentSegmentStartedAt = .now
            startSegmentMonitors()
            startEscape()
            if playSound { RecordingSounds.playStart() }
            logger.info("Recording segment started")
        } catch AudioRecorderError.microphoneDenied {
            clearCurrentSegment()
            returnFromRecording()
            reportError(.microphoneDenied)
        } catch {
            clearCurrentSegment()
            returnFromRecording()
            logger.error("startSegment failed: \(error.localizedDescription, privacy: .public) (code=\((error as NSError).code)) isResumingAfterSplit=\(self.isResumingAfterSplit)")
            reportError(.recordingFailed(error.localizedDescription))
        }
    }

    func stop() {
        guard recorder.isRunning else { return }

        state = .finishing
        stopSegmentMonitors()

        let url = recorder.stop()
        currentRecordingURL = nil
        currentSegmentStartedAt = nil

        var segments = pendingAudioSegments
        pendingAudioSegments = []
        let priorSegmentsAudio = pendingSegmentsAudioSeconds
        pendingSegmentsAudioSeconds = 0

        if let url {
            segments.append(url)
        } else if segments.isEmpty {
            reportError(.recordingFailed("Audio recording failed to save."))
            if queue.queuedCount == 0 {
                state = .idle
                monitors.stopEscape()
            }
            return
        } else {
            logger.warning("Final segment failed to save — transcribing prior segments only")
        }

        let finalSegmentAudio = url.map { audioDuration(at: $0) } ?? 0
        enqueueTranscription(urls: segments, audioSeconds: priorSegmentsAudio + finalSegmentAudio)
    }

    private func enqueueTranscription(urls: [URL], audioSeconds: Double) {
        let manager = ModelManager()
        guard let modelURL = manager.selectedModelURL else {
            for url in urls { try? FileManager.default.removeItem(at: url) }
            reportError(.noModel)
            return
        }
        queue.enqueue(
            urls: urls,
            audioSeconds: audioSeconds,
            modelURL: modelURL,
            initialPrompt: dictionaryPrompt(),
            settings: transcriptionSettings(),
            sessionStartedAt: sessionStartedAt,
            onComplete: { [weak self] outcome in
                guard let self else { return }
                switch outcome {
                case .success(let text, _):
                    if !text.isEmpty { self.sessionTexts.append(text) }
                case .failure(let error):
                    self.reportError(error)
                case .cancelled:
                    break
                }
            },
            onIdle: { [weak self] in
                guard let self, case .finishing = self.state else { return }
                self.finishSession()
            }
        )
    }

    private func finishSession() {
        monitors.stopEscape()

        let combined = sessionTexts.joined(separator: " ")
        sessionTexts = []
        sessionStartedAt = nil

        let finalText = SnippetStore.apply(to: combined)
        guard !finalText.isEmpty else {
            lastCompletion = .empty
            RecordingSounds.playEmpty()
            state = .idle
            return
        }

        if AppDefaults.keepRecentTranscripts {
            history.add(finalText)
        }

        Task { [weak self] in
            guard let self else { return }
            switch await Paster.paste(finalText) {
            case .pasted:
                self.lastCompletion = .pasted
                RecordingSounds.playPaste()
            case .copied:
                self.lastCompletion = .copied
                RecordingSounds.playPaste()
            case .failedNoAccessibility:
                self.lastCompletion = .failed("Accessibility permission needed")
                self.persistentError = .noAccessibility
                Paster.requestAccessibilityPermission()
            }
            self.state = .idle
        }
    }

    private func transcriptionSettings() -> TranscriptionSettings {
        TranscriptionSettings(
            language: AppDefaults.selectedLanguage,
            paragraphSplitting: AppDefaults.paragraphSplitting,
            minSilenceDuration: AppDefaults.silenceThreshold
        )
    }

    private func dictionaryPrompt() -> String? {
        DictionaryPromptBuilder.prompt(from: AppDefaults.dictionaryEntries)
    }
}
