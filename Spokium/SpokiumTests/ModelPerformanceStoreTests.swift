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
}
