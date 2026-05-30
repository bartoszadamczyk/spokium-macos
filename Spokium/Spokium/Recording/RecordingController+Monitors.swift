import AppKit
import Foundation
import OSLog

extension RecordingController {
    func startLevelMonitoring() {
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

    func stopLevelMonitoring() {
        levelTimer?.invalidate()
        levelTimer = nil
        inputLevel = 0
    }

    func startAutoStopTask() {
        autoStopTask?.cancel()
        let minutes = AppDefaults.maxRecordingMinutes
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

    func startSplitTimer() {
        splitTimer?.invalidate()
        let minutes = AppDefaults.autoSplitMinutes
        guard minutes > 0 else { return }
        splitTimer = Timer.scheduledTimer(withTimeInterval: minutes * 60, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.logger.info("Auto-splitting recording segment")
                self?.splitCurrentSegment()
            }
        }
    }

    func stopSplitTimer() {
        splitTimer?.invalidate()
        splitTimer = nil
    }

    func startEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor [weak self] in
                self?.cancel()
            }
        }
    }

    func stopEscapeMonitor() {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
    }
}
