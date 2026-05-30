import Foundation

// Aggregate transcription performance per model. Stores only counts and durations — never text.
enum ModelPerformanceStore {
    struct Record: Codable {
        var count: Int
        var totalAudioSeconds: Double
        var totalTranscribeSeconds: Double

        var speedRatio: Double {
            guard totalTranscribeSeconds > 0 else { return 0 }
            return totalAudioSeconds / totalTranscribeSeconds
        }
    }

    private static let key = "modelPerformance"

    static func record(modelStem: String, audioSeconds: Double, transcribeSeconds: Double) {
        guard let merged = merge(into: load()[modelStem], audioSeconds: audioSeconds, transcribeSeconds: transcribeSeconds)
        else { return }
        var all = load()
        all[modelStem] = merged
        save(all)
    }

    // Pure aggregation: returns the updated Record, or nil if the inputs are non-positive
    // and should be ignored. Exposed so tests don't have to touch UserDefaults.
    nonisolated static func merge(
        into existing: Record?,
        audioSeconds: Double,
        transcribeSeconds: Double
    ) -> Record? {
        guard audioSeconds > 0, transcribeSeconds > 0 else { return nil }
        var entry = existing ?? Record(count: 0, totalAudioSeconds: 0, totalTranscribeSeconds: 0)
        entry.count += 1
        entry.totalAudioSeconds += audioSeconds
        entry.totalTranscribeSeconds += transcribeSeconds
        return entry
    }

    static func read(modelStem: String) -> Record? {
        let r = load()[modelStem]
        return (r?.count ?? 0) > 0 ? r : nil
    }

    private static func load() -> [String: Record] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let dict = try? JSONDecoder().decode([String: Record].self, from: data)
        else { return [:] }
        return dict
    }

    private static func save(_ dict: [String: Record]) {
        guard let data = try? JSONEncoder().encode(dict) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

extension ModelPerformanceStore.Record {
    var formattedSpeed: String {
        let r = speedRatio
        guard r > 0 else { return "" }
        return r < 10
            ? String(format: "%.1f× real-time", r)
            : String(format: "%.0f× real-time", r)
    }

    var summary: String {
        let runs = count == 1 ? "1 run" : "\(count) runs"
        return "\(formattedSpeed) · \(runs)"
    }
}
