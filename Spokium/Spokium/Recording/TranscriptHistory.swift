import Foundation

// In-memory, opt-in store of the most recent N transcripts. Used to let the user
// re-copy a transcript shortly after it was produced (e.g. when the original
// paste landed in the wrong window).
//
// Privacy posture:
//   - Never persisted to disk.
//   - Capped at `maxCount` entries (oldest dropped first).
//   - Entries expire after `retention` seconds.
//   - Cleared on app quit via RecordingController.cleanup().
//   - Cleared on demand via clear().
//   - Only populated when AppDefaults.keepRecentTranscripts is true.
final class TranscriptHistory {
    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let timestamp: Date

        // Single-line preview suitable for an NSMenuItem title.
        var preview: String {
            let single = text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            if single.count <= 40 { return single }
            return String(single.prefix(40)) + "…"
        }
    }

    private(set) var entries: [Entry] = []
    private let maxCount: Int
    private let retention: TimeInterval
    private var pruneTimer: Timer?

    init(maxCount: Int = 5, retention: TimeInterval = 5 * 60) {
        self.maxCount = maxCount
        self.retention = retention
    }

    func add(_ text: String) {
        prune()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        entries.insert(Entry(text: text, timestamp: Date()), at: 0)
        if entries.count > maxCount {
            entries.removeLast(entries.count - maxCount)
        }
        startTimerIfNeeded()
    }

    func clear() {
        entries.removeAll()
        stopTimer()
    }

    // Drops entries older than `retention`. Exposed for testing; also called
    // internally on every add and periodically from the prune timer.
    func prune(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-retention)
        entries.removeAll { $0.timestamp < cutoff }
        if entries.isEmpty {
            stopTimer()
        }
    }

    private func startTimerIfNeeded() {
        guard pruneTimer == nil else { return }
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.prune()
            }
        }
    }

    private func stopTimer() {
        pruneTimer?.invalidate()
        pruneTimer = nil
    }
}
