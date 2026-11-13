import Foundation

// Aggregate transcription performance per model. Stores only counts and durations — never text.
enum ModelPerformanceStore {
    nonisolated struct Run: Codable, Equatable {
        var audioSeconds: Double
        var transcribeSeconds: Double
        var speed: Double { audioSeconds / transcribeSeconds }
    }

    nonisolated struct Record: Codable {
        var count: Int
        var totalAudioSeconds: Double
        var totalTranscribeSeconds: Double
        // The latest runs (nil in data saved before this was added). Speed is computed
        // from these so one odd run can't skew it for good — e.g. a dictation that waited
        // minutes for a Neural Engine compile, or a chunk that took almost no time.
        var recent: [Run]? = nil

        var speedRatio: Double {
            if let recent, !recent.isEmpty {
                return ModelPerformanceStore.robustSpeed(of: recent)
            }
            guard totalTranscribeSeconds > 0 else { return 0 }
            return totalAudioSeconds / totalTranscribeSeconds
        }
    }

    nonisolated static let recentLimit = 50
    // Runs more than this factor away from the median speed are left out.
    nonisolated static let outlierFactor = 3.0

    // Audio-weighted speed over the runs within outlierFactor of the median speed.
    // With fewer than 5 runs there's no distribution to judge against, so all count.
    nonisolated static func robustSpeed(of runs: [Run]) -> Double {
        let valid = runs.filter { $0.audioSeconds > 0 && $0.transcribeSeconds > 0 }
        guard !valid.isEmpty else { return 0 }
        var kept = valid
        if valid.count >= 5 {
            let speeds = valid.map(\.speed).sorted()
            let median = speeds.count % 2 == 1
                ? speeds[speeds.count / 2]
                : (speeds[speeds.count / 2 - 1] + speeds[speeds.count / 2]) / 2
            kept = valid.filter { $0.speed <= median * outlierFactor && $0.speed >= median / outlierFactor }
        }
        let audio = kept.reduce(0) { $0 + $1.audioSeconds }
        let time = kept.reduce(0) { $0 + $1.transcribeSeconds }
        return time > 0 ? audio / time : 0
    }

    // Runs with the Core ML (Neural Engine) encoder are tracked separately from plain
    // Metal/GPU runs so the two can be compared. GPU keeps the bare stem, so existing
    // stats carry over.
    nonisolated static func key(modelStem: String, coreML: Bool) -> String {
        coreML ? "\(modelStem)+coreml" : modelStem
    }

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
        var recent = entry.recent ?? []
        recent.append(Run(audioSeconds: audioSeconds, transcribeSeconds: transcribeSeconds))
        entry.recent = Array(recent.suffix(recentLimit))
        return entry
    }

    static func read(modelStem: String) -> Record? {
        let r = load()[modelStem]
        return (r?.count ?? 0) > 0 ? r : nil
    }

    private static func load() -> [String: Record] {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.modelPerformance),
              let dict = try? JSONDecoder().decode([String: Record].self, from: data)
        else { return [:] }
        return dict
    }

    private static func save(_ dict: [String: Record]) {
        guard let data = try? JSONEncoder().encode(dict) else { return }
        UserDefaults.standard.set(data, forKey: DefaultsKey.modelPerformance)
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
