import AppKit
import Foundation
import OSLog

// Owns the timers/monitors that bracket a recording session:
//   - level polling (50ms RMS samples → smoothed Float)
//   - auto-stop deadline
//   - global Esc keyDown monitor
//
// All callbacks run on MainActor. RecordingController holds one instance and
// drives starts/stops at the appropriate state-machine transitions.
//
// Mid-recording segment splitting (used for device-switch handoff) is driven
// from RecordingController.splitCurrentSegment directly — no timer involved.
final class RecordingMonitors {
    private var levelTimer: Timer?
    private var autoStopTask: Task<Void, Never>?
    private var escapeMonitor: Any?
    private var smoothedLevel: Float = 0

    func startLevel(recorder: AudioRecorder, onUpdate: @escaping @MainActor (Float) -> Void) {
        levelTimer?.invalidate()
        smoothedLevel = 0
        let smoothing: Float = 0.3
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let raw = recorder.currentLevel
                self.smoothedLevel = self.smoothedLevel * (1 - smoothing) + raw * smoothing
                onUpdate(self.smoothedLevel)
            }
        }
    }

    func stopLevel() {
        levelTimer?.invalidate()
        levelTimer = nil
        smoothedLevel = 0
    }

    func startAutoStop(after minutes: Double, onFire: @escaping @MainActor () -> Void) {
        autoStopTask?.cancel()
        guard minutes > 0 else { return }
        let nanoseconds = UInt64(minutes * 60 * 1_000_000_000)
        autoStopTask = Task {
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run { onFire() }
        }
    }

    func cancelAutoStop() {
        autoStopTask?.cancel()
        autoStopTask = nil
    }

    func startEscape(onPress: @escaping @MainActor () -> Void) {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in onPress() }
        }
    }

    func stopEscape() {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
    }

    func stopAll() {
        stopLevel()
        cancelAutoStop()
        stopEscape()
    }
}
