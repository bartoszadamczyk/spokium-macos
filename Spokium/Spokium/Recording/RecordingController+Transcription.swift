import AVFoundation
import Foundation
import OSLog

extension RecordingController {
    func start() async {
        lastError = nil
        persistentError = nil
        pendingStartCancel = false
        sessionTexts = []
        pendingTranscriptionCount = 0
        pendingTranscriptionAudioSeconds = 0
        pendingSegmentsAudioSeconds = 0
        currentSegmentStartedAt = nil
        currentTranscriptionStartedAt = nil
        lastTranscriptionTask = nil
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
            startLevelMonitoring()
            startEscapeMonitor()
            startAutoStopTask()
            startSplitTimer()
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
        stopLevelMonitoring()
        stopSplitTimer()
        autoStopTask?.cancel()
        autoStopTask = nil

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
            if pendingTranscriptionCount == 0 {
                state = .idle
                stopEscapeMonitor()
            }
            return
        } else {
            logger.warning("Final segment failed to save — transcribing prior segments only")
        }

        let finalSegmentAudio = url.map { audioDuration(at: $0) } ?? 0
        enqueueTranscription(urls: segments, audioSeconds: priorSegmentsAudio + finalSegmentAudio)
    }

    private func enqueueTranscription(urls: [URL], audioSeconds: Double) {
        guard !urls.isEmpty else { return }
        pendingTranscriptionCount += 1
        pendingTranscriptionAudioSeconds += audioSeconds
        let previous = lastTranscriptionTask
        let task = Task { [weak self] in
            _ = await previous?.value
            guard !Task.isCancelled, let self else {
                for url in urls { try? FileManager.default.removeItem(at: url) }
                return
            }
            await self.transcribeSession(urls: urls, audioSeconds: audioSeconds)
        }
        lastTranscriptionTask = task
        activeTasks.append(task)
    }

    private func transcribeSession(urls: [URL], audioSeconds: Double) async {
        defer {
            for url in urls { try? FileManager.default.removeItem(at: url) }
            pendingTranscriptionCount -= 1
            pendingTranscriptionAudioSeconds = max(0, pendingTranscriptionAudioSeconds - audioSeconds)
            if pendingTranscriptionCount == 0 {
                currentTranscriptionStartedAt = nil
            }
            activeTasks.removeAll { $0.isCancelled }
            if pendingTranscriptionCount == 0, case .finishing = state {
                finishSession()
            }
        }

        guard !Task.isCancelled else { return }

        let manager = ModelManager()
        guard let modelURL = manager.selectedModelURL else {
            reportError(.noModel)
            return
        }

        if transcriber?.modelURL != modelURL { transcriber = nil }
        let transcriber = self.transcriber ?? Transcriber(modelURL: modelURL)
        self.transcriber = transcriber

        currentTranscriptionStartedAt = .now

        // Load and concatenate all segment audio into one sample array at 16 kHz mono.
        // AudioLoader.loadResampled handles format differences between segments (e.g. after a device switch).
        var allSamples: [Float] = []
        var totalAudioSeconds: Double = 0
        for url in urls {
            guard !Task.isCancelled else { return }
            do {
                if let audioFile = try? AVAudioFile(forReading: url) {
                    totalAudioSeconds += Double(audioFile.length) / audioFile.processingFormat.sampleRate
                }
                let samples = try AudioLoader.loadResampled(url: url)
                allSamples.append(contentsOf: samples)
            } catch {
                logger.warning("Failed to load segment \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        // 16 kHz × 0.5 s = 8 000 samples minimum
        guard allSamples.count >= 8_000 else {
            logger.info("Skipping recording too short for speech (\(String(format: "%.2f", totalAudioSeconds))s total)")
            return
        }

        let transcribeStart = ContinuousClock.now
        let recordingDuration = sessionStartedAt.map { ContinuousClock.now - $0 } ?? .zero

        do {
            let result = try await transcriber.transcribe(
                samples: allSamples,
                initialPrompt: dictionaryPrompt(),
                settings: transcriptionSettings()
            )

            guard !Task.isCancelled else { return }

            let transcriptionDuration = ContinuousClock.now - transcribeStart
            let modelStem = modelURL.deletingPathExtension().lastPathComponent
            logger.info("Transcribed: model=\(modelStem, privacy: .public), language=\(result.language, privacy: .public), chars=\(result.text.count), segments=\(urls.count), audio=\(String(format: "%.1f", totalAudioSeconds))s, recording=\(recordingDuration, privacy: .public), transcription=\(transcriptionDuration, privacy: .public)")

            let (sec, atto) = transcriptionDuration.components
            ModelPerformanceStore.record(
                modelStem: modelStem,
                audioSeconds: totalAudioSeconds,
                transcribeSeconds: Double(sec) + Double(atto) * 1e-18
            )

            if !result.text.isEmpty {
                sessionTexts.append(result.text)
            }
        } catch TranscriberError.cancelled {
            logger.info("Transcription aborted")
        } catch {
            logger.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
            reportError(.transcriptionFailed(error.localizedDescription))
        }
    }

    private func finishSession() {
        stopEscapeMonitor()

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
        let defaults = UserDefaults.standard
        return TranscriptionSettings(
            language: defaults.string(forKey: "selectedLanguage") ?? "auto",
            paragraphSplitting: defaults.object(forKey: "paragraphSplitting") as? Bool ?? true,
            minSilenceDuration: defaults.object(forKey: "silenceThreshold") as? Double ?? 3.0
        )
    }

    private func dictionaryPrompt() -> String? {
        DictionaryPromptBuilder.prompt(
            from: UserDefaults.standard.string(forKey: "dictionaryEntries") ?? ""
        )
    }
}
