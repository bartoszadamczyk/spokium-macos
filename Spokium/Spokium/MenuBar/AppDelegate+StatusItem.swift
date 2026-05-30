import AppKit
import SwiftUI

extension AppDelegate {
    func renderMenuBarIcon(recording: Bool) {
        let renderer = ImageRenderer(content: MenuBarIcon(recording: recording))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2.0

        if let image = renderer.nsImage {
            image.isTemplate = !recording
            statusItem.button?.image = image
        }
    }

    func startPulse() {
        pulseOn = true
        statusItem.button?.alphaValue = 1.0
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pulseOn.toggle()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.6
                    self.statusItem.button?.animator().alphaValue = self.pulseOn ? 1.0 : 0.45
                }
            }
        }
    }

    func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        pulseOn = true
        statusItem.button?.alphaValue = 1.0
    }

    func refreshQueueStatus() {
        guard controller.state != .idle else {
            queueStatusItem.isHidden = true
            queueStatusItem.title = ""
            return
        }

        var parts: [String] = []

        let isRecording = controller.state == .recording || controller.state == .starting
        if isRecording {
            parts.append("Recording \(formatSeconds(controller.recordingAudioSeconds))")
        }

        if let eta = controller.transcriptionEstimateSeconds {
            parts.append("Transcribing ~\(formatSeconds(eta)) left")
        } else if controller.queuedTranscriptionCount > 0 {
            let n = controller.queuedTranscriptionCount
            parts.append(n == 1 ? "Transcribing" : "Transcribing \(n)")
        }

        if parts.isEmpty {
            queueStatusItem.isHidden = true
            return
        }
        queueStatusItem.title = parts.joined(separator: " · ")
        queueStatusItem.isHidden = false
    }

    func startQueueStatusTimer() {
        stopQueueStatusTimer()
        // Scheduled on .common so it fires during NSEventTrackingRunLoopMode
        // (the run loop mode used while a menu is open).
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshQueueStatus()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        queueStatusTimer = timer
    }

    func stopQueueStatusTimer() {
        queueStatusTimer?.invalidate()
        queueStatusTimer = nil
    }

    private func formatSeconds(_ value: Double) -> String {
        let total = max(0, Int(value.rounded()))
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
