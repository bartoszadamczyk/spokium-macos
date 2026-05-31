import AVFoundation
import Foundation
import Testing
@testable import Spokium

@MainActor
struct AudioLoaderTests {
    // Generates a temporary audio file containing a sine wave at the given
    // frequency, amplitude, duration, sample rate, and channel count.
    // Returns the URL; caller is responsible for cleanup.
    private func writeSineWave(
        frequency: Double = 1_000,
        amplitude: Float = 0.5,
        duration: Double,
        sampleRate: Double,
        channels: AVAudioChannelCount = 1
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audioloader-\(UUID().uuidString).caf")

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ) else {
            throw NSError(domain: "AudioLoaderTests", code: 0)
        }

        let file = try AVAudioFile(forWriting: url, settings: format.settings)

        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "AudioLoaderTests", code: 1)
        }
        buffer.frameLength = frameCount

        let twoPi: Float = 2 * .pi
        let step = twoPi * Float(frequency) / Float(sampleRate)
        let channelData = buffer.floatChannelData!
        for channel in 0..<Int(channels) {
            let ptr = channelData[channel]
            for i in 0..<Int(frameCount) {
                ptr[i] = amplitude * sin(step * Float(i))
            }
        }

        try file.write(from: buffer)
        return url
    }

    // Generates a temporary mono audio file at `sampleRate` consisting of
    // segments. Each segment is either loud (sine at amplitude 0.5) or silent.
    private func writeSegmentedSignal(
        segments: [(loud: Bool, seconds: Double)],
        sampleRate: Double
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audioloader-seg-\(UUID().uuidString).caf")

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "AudioLoaderTests", code: 0)
        }

        let file = try AVAudioFile(forWriting: url, settings: format.settings)

        let twoPi: Float = 2 * .pi
        let step = twoPi * 1_000 / Float(sampleRate)
        var phase: Float = 0

        for segment in segments {
            let frameCount = AVAudioFrameCount(sampleRate * segment.seconds)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                throw NSError(domain: "AudioLoaderTests", code: 1)
            }
            buffer.frameLength = frameCount
            let ptr = buffer.floatChannelData![0]
            for i in 0..<Int(frameCount) {
                if segment.loud {
                    ptr[i] = 0.5 * sin(phase)
                    phase += step
                } else {
                    ptr[i] = 0
                }
            }
            try file.write(from: buffer)
        }
        return url
    }

    // NOTE: AVAudioConverter adds a "tail" of samples beyond the strict input
    // duration — even when no rate conversion is needed (16 kHz → 16 kHz adds
    // ~640 samples here). The tail varies with source rate and channel layout.
    // Whisper consumes the extra samples without issue, so we tolerate ±1000
    // (~6%) rather than insist on exact counts.
    private let sampleCountTolerance = 1_000

    @Test func loadResampled_returnsApproximatelyExpectedSampleCount_for1SecondAt48kHz() throws {
        let url = try writeSineWave(duration: 1.0, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = try AudioLoader.loadResampled(url: url)

        #expect(abs(samples.count - 16_000) < sampleCountTolerance)
    }

    @Test func loadResampled_returnsApproximatelyExpectedSampleCount_for1SecondAt44_1kHz() throws {
        let url = try writeSineWave(duration: 1.0, sampleRate: 44_100)
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = try AudioLoader.loadResampled(url: url)

        #expect(abs(samples.count - 16_000) < sampleCountTolerance)
    }

    @Test func loadResampled_returnsApproximatelyExpectedSampleCount_for1SecondAt16kHz_noResample() throws {
        let url = try writeSineWave(duration: 1.0, sampleRate: 16_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = try AudioLoader.loadResampled(url: url)

        #expect(abs(samples.count - 16_000) < sampleCountTolerance)
    }

    @Test func loadResampled_handlesStereoInput_byDownmixing() throws {
        let url = try writeSineWave(duration: 1.0, sampleRate: 48_000, channels: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = try AudioLoader.loadResampled(url: url)

        #expect(abs(samples.count - 16_000) < sampleCountTolerance)
    }

    @Test func loadResampled_preservesApproximateRMS_forSineInput() throws {
        // RMS of an ideal sine at amplitude 0.5 is 0.5 / sqrt(2) ≈ 0.354.
        let url = try writeSineWave(amplitude: 0.5, duration: 1.0, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = try AudioLoader.loadResampled(url: url)

        var sumSq: Float = 0
        for s in samples { sumSq += s * s }
        let rms = (sumSq / Float(samples.count)).squareRoot()

        #expect(abs(rms - 0.354) < 0.05)
    }

    @Test func loadResampled_throws_forNonexistentFile() {
        let url = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString).caf")

        #expect(throws: (any Error).self) {
            _ = try AudioLoader.loadResampled(url: url)
        }
    }

    @Test func silenceDetector_findsGap_inResampledRealAudio() throws {
        // 1 s loud + 2 s silent + 1 s loud, written at 48 kHz, resampled to 16 kHz.
        let url = try writeSegmentedSignal(
            segments: [(true, 1.0), (false, 2.0), (true, 1.0)],
            sampleRate: 48_000
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = try AudioLoader.loadResampled(url: url)

        // After resampling there should be a detectable 2 s silence gap that
        // crosses the 1.0 s threshold. Midpoint ≈ 2.0 s into the buffer.
        let breaks = SilenceDetector.breaks(
            samples: samples,
            sampleRate: 16_000,
            minSilenceDuration: 1.0
        )
        #expect(breaks.count == 1)
        if let first = breaks.first {
            #expect(abs(first - 2.0) < 0.2)
        }
    }
}
