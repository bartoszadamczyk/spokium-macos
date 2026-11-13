import Testing
@testable import Spokium

@MainActor
struct ModelPerformanceStoreTests {
    private func record(count: Int, audio: Double, transcribe: Double) -> ModelPerformanceStore.Record {
        ModelPerformanceStore.Record(
            count: count,
            totalAudioSeconds: audio,
            totalTranscribeSeconds: transcribe
        )
    }

    @Test func firstRecord_seedsCountsFromZero() {
        let merged = ModelPerformanceStore.merge(into: nil, audioSeconds: 10, transcribeSeconds: 2)
        #expect(merged?.count == 1)
        #expect(merged?.totalAudioSeconds == 10)
        #expect(merged?.totalTranscribeSeconds == 2)
    }

    @Test func subsequentRecord_accumulates() {
        let existing = record(count: 1, audio: 10, transcribe: 2)
        let merged = ModelPerformanceStore.merge(into: existing, audioSeconds: 5, transcribeSeconds: 1)
        #expect(merged?.count == 2)
        #expect(merged?.totalAudioSeconds == 15)
        #expect(merged?.totalTranscribeSeconds == 3)
    }

    @Test func zeroAudio_isIgnored() {
        #expect(ModelPerformanceStore.merge(into: nil, audioSeconds: 0, transcribeSeconds: 1) == nil)
    }

    @Test func zeroTranscribe_isIgnored() {
        #expect(ModelPerformanceStore.merge(into: nil, audioSeconds: 1, transcribeSeconds: 0) == nil)
    }

    @Test func negativeInputs_areIgnored() {
        #expect(ModelPerformanceStore.merge(into: nil, audioSeconds: -1, transcribeSeconds: 1) == nil)
        #expect(ModelPerformanceStore.merge(into: nil, audioSeconds: 1, transcribeSeconds: -1) == nil)
    }

    @Test func speedRatio_isAudioOverTranscribe() {
        let r = record(count: 1, audio: 20, transcribe: 5)
        #expect(r.speedRatio == 4.0)
    }

    @Test func speedRatio_returnsZero_whenNoTranscribeTimeRecorded() {
        let r = record(count: 1, audio: 20, transcribe: 0)
        #expect(r.speedRatio == 0)
    }

    @Test func formattedSpeed_oneDecimal_belowTenX() {
        let r = record(count: 1, audio: 10, transcribe: 2)
        #expect(r.formattedSpeed == "5.0× real-time")
    }

    @Test func formattedSpeed_noDecimal_atOrAboveTenX() {
        let r = record(count: 1, audio: 200, transcribe: 10)
        #expect(r.formattedSpeed == "20× real-time")
    }

    @Test func formattedSpeed_isEmpty_whenNoData() {
        let r = record(count: 0, audio: 0, transcribe: 0)
        #expect(r.formattedSpeed.isEmpty)
    }

    @Test func summary_singularRunWording() {
        let r = record(count: 1, audio: 10, transcribe: 2)
        #expect(r.summary == "5.0× real-time · 1 run")
    }

    @Test func summary_pluralRunsWording() {
        let r = record(count: 3, audio: 10, transcribe: 2)
        #expect(r.summary == "5.0× real-time · 3 runs")
    }

    @Test
    func key_separatesCoreMLFromGPU() {
        #expect(ModelPerformanceStore.key(modelStem: "ggml-large-v3", coreML: false) == "ggml-large-v3")
        #expect(ModelPerformanceStore.key(modelStem: "ggml-large-v3", coreML: true) == "ggml-large-v3+coreml")
    }
}

@MainActor
struct RobustSpeedTests {
    private typealias Run = ModelPerformanceStore.Run

    @Test
    func hungRun_doesNotSkewSpeed() {
        // Ten normal runs at 10× real-time, then one that waited 10 minutes.
        let normal = Array(repeating: Run(audioSeconds: 10, transcribeSeconds: 1), count: 10)
        let hung = Run(audioSeconds: 10, transcribeSeconds: 600)
        #expect(abs(ModelPerformanceStore.robustSpeed(of: normal + [hung]) - 10) < 0.01)
    }

    @Test
    func nearZeroRun_doesNotInflateSpeed() {
        let normal = Array(repeating: Run(audioSeconds: 10, transcribeSeconds: 1), count: 10)
        let instant = Run(audioSeconds: 10, transcribeSeconds: 0.001)
        #expect(abs(ModelPerformanceStore.robustSpeed(of: normal + [instant]) - 10) < 0.01)
    }

    @Test
    func fewRuns_allCount() {
        let runs = [Run(audioSeconds: 10, transcribeSeconds: 1), Run(audioSeconds: 10, transcribeSeconds: 9)]
        #expect(abs(ModelPerformanceStore.robustSpeed(of: runs) - 2) < 0.01)
    }

    @Test
    func recentRuns_overrideSkewedLegacyTotals_andAreCapped() {
        // Legacy totals from before `recent` existed, skewed by a hang.
        var record: ModelPerformanceStore.Record? = ModelPerformanceStore.Record(
            count: 3, totalAudioSeconds: 30, totalTranscribeSeconds: 900)
        #expect((record?.speedRatio ?? 0) < 0.1)
        for _ in 0..<60 {
            record = ModelPerformanceStore.merge(into: record, audioSeconds: 10, transcribeSeconds: 1)
        }
        #expect(record?.recent?.count == ModelPerformanceStore.recentLimit)
        #expect(record?.count == 63)
        #expect(abs((record?.speedRatio ?? 0) - 10) < 0.01)
    }
}
