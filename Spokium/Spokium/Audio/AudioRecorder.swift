@preconcurrency import AVFoundation
import AudioToolbox
import OSLog
import Synchronization

enum AudioRecorderError: Error, LocalizedError {
    case microphoneDenied
    case alreadyRunning
    case writeFailed
    case deviceNotReady
    case startTimedOut

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: "Microphone access was denied."
        case .alreadyRunning: "A recording is already running."
        case .writeFailed: "The recording couldn't be written to disk."
        case .deviceNotReady: "The microphone isn't ready yet."
        case .startTimedOut: "The microphone didn't respond. Try again, or pick another input device."
        }
    }
}

private nonisolated final class WriteErrorFlag: Sendable {
    let failed = Atomic<Bool>(false)
}

private nonisolated final class AudioLevelMeter: Sendable {
    private let bits = Atomic<UInt32>(0)
    var level: Float { Float(bitPattern: bits.load(ordering: .relaxed)) }
    func store(_ value: Float) { bits.store(value.bitPattern, ordering: .relaxed) }
    func reset() { bits.store(0, ordering: .relaxed) }
}

// Receives 16 kHz mono Float32 from the tap for live transcription. The tap appends
// from the audio thread; RecordingController drains it on the main actor.
nonisolated final class LiveSampleSink: Sendable {
    private let buffer = Mutex<[Float]>([])

    func append(_ samples: UnsafeBufferPointer<Float>) {
        buffer.withLock { $0.append(contentsOf: samples) }
    }

    func drain() -> [Float] {
        buffer.withLock { samples in
            defer { samples = [] }
            return samples
        }
    }
}

// One running AVAudioEngine + output file. Only ever touched on `AudioRecorder.engineQueue`
// (serially), hence @unchecked Sendable.
private nonisolated final class EngineSession: @unchecked Sendable {
    private(set) var engine: AVAudioEngine?
    let fileURL: URL

    private init(engine: AVAudioEngine, fileURL: URL) {
        self.engine = engine
        self.fileURL = fileURL
    }

    // Builds, configures and starts an engine. Blocking CoreAudio calls live here, which
    // is why this must never run on the main thread.
    static func make(
        fileURL: URL,
        deviceID: AudioDeviceID?,
        flag: WriteErrorFlag,
        meter: AudioLevelMeter,
        liveSink: LiveSampleSink?,
        logger: Logger
    ) throws -> EngineSession {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        if var deviceID, let audioUnit = inputNode.audioUnit {
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status != noErr {
                logger.error("Failed to apply selected input device (OSStatus \(status)) — falling back to system default")
            }
        }

        // installTap raises an uncatchable ObjC exception on a 0 Hz / 0-channel format or
        // one that differs from the bus's output format. Devices that are still waking up
        // (Continuity Mic, AirPods) report exactly that, so throw and let the caller retry.
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            logger.warning("Input format not ready (\(format.sampleRate) Hz, \(format.channelCount) ch)")
            throw AudioRecorderError.deviceNotReady
        }

        let file = try AVAudioFile(forWriting: fileURL, settings: format.settings)
        flag.failed.store(false, ordering: .relaxed)
        meter.reset()

        let live = liveSink.flatMap { LiveResampler(from: format, sink: $0) }
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { @Sendable buffer, _ in
            do {
                try file.write(from: buffer)
            } catch {
                flag.failed.store(true, ordering: .relaxed)
            }
            live?.push(buffer)

            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { return }
            var sum: Float = 0
            for i in 0..<frameLength {
                sum += channelData[i] * channelData[i]
            }
            meter.store((sum / Float(frameLength)).squareRoot())
        }

        let session = EngineSession(engine: engine, fileURL: fileURL)
        do {
            try engine.start()
        } catch {
            session.teardown()
            throw error
        }
        return session
    }

    // Releasing the engine also releases the tap closure, which closes the AVAudioFile
    // and flushes it to disk. Releasing (not just stopping) matters for Bluetooth: a
    // retained engine keeps the headset in the low-quality HFP profile.
    func teardown() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        engine.reset()
        self.engine = nil
    }
}

// Resumes a continuation at most once — either with the queue's result or the timeout.
private nonisolated final class ResumeOnce<T: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<T, any Error>?>

    init(_ continuation: CheckedContinuation<T, any Error>) {
        self.continuation = Mutex(continuation)
    }

    @discardableResult
    func resume(with result: Result<T, any Error>) -> Bool {
        guard let continuation = continuation.withLock({ c in defer { c = nil }; return c }) else { return false }
        continuation.resume(with: result)
        return true
    }
}

@MainActor
final class AudioRecorder {
    // All AVAudioEngine work happens here, serially. CoreAudio calls can block for a
    // long time (or indefinitely) when coreaudiod is busy — e.g. after rapid start/stop
    // toggling — and doing them on the main thread froze the whole app. Serial order
    // also guarantees an engine is fully torn down before the next one is built.
    private nonisolated static let engineQueue = DispatchQueue(label: "com.spokium.audio-engine", qos: .userInitiated)
    private static let startTimeout: Duration = .seconds(5)
    private static let stopTimeout: Duration = .seconds(3)

    private var session: EngineSession?
    private var isStarting = false
    private let writeErrorFlag = WriteErrorFlag()
    private let levelMeter = AudioLevelMeter()
    private var configChangeObserver: NSObjectProtocol?
    private let logger = Logger(subsystem: "com.spokium.mac", category: "AudioRecorder")

    var onConfigurationChange: (@MainActor () -> Void)?
    // Set for live-transcription sessions; applies from the next start().
    var liveSink: LiveSampleSink?


    // UID of the device the running recording uses. Device switches compare against
    // this rather than the stored setting, which Settings has already overwritten.
    private(set) var activeDeviceUID: String?

    var isRunning: Bool { session != nil }
    var currentLevel: Float { levelMeter.level }

    func start(to fileURL: URL) async throws {
        guard session == nil, !isStarting else { throw AudioRecorderError.alreadyRunning }
        isStarting = true
        defer { isStarting = false }

        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else { throw AudioRecorderError.microphoneDenied }

        let uid = AppDefaults.selectedInputDevice
        var device: AudioInputDevice?
        if !uid.isEmpty {
            device = AudioInputDevice.available().first(where: { $0.uid == uid })
            if device == nil {
                // Normally already re-pointed when the device went away; this covers a
                // device that was gone before launch. Saved, so the menu shows it.
                device = AudioInputDevice.nextBest()
                AppDefaults.selectedInputDevice = device?.uid ?? ""
                logger.error("Input device \(uid, privacy: .public) not available — switched selection to \(device?.name ?? "System Default", privacy: .public)")
            }
        }

        let selectedDeviceID = device?.deviceID
        let flag = writeErrorFlag
        let meter = levelMeter
        let sink = liveSink
        let logger = logger
        let session = try await Self.onEngineQueue(timeout: Self.startTimeout, discard: { $0.teardown() }) {
            try EngineSession.make(fileURL: fileURL, deviceID: selectedDeviceID, flag: flag, meter: meter, liveSink: sink, logger: logger)
        }
        self.session = session
        activeDeviceUID = device?.uid ?? AudioInputDevice.defaultInputUID()

        let startInstant = ContinuousClock.now
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: session.engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if ContinuousClock.now - startInstant < .seconds(2) { return }
                self.onConfigurationChange?()
            }
        }
    }

    func stop() async -> URL? {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        guard let session else { return nil }
        self.session = nil
        activeDeviceUID = nil

        do {
            try await Self.onEngineQueue(timeout: Self.stopTimeout, discard: { _ in }) { session.teardown() }
        } catch {
            logger.error("Audio engine teardown timed out — discarding segment")
            return nil
        }

        let url = session.fileURL
        if writeErrorFlag.failed.load(ordering: .relaxed) {
            logger.error("Audio write errors occurred during recording")
            return nil
        }
        // Verify the file actually made it to disk. On very short recordings (or when no
        // buffers ever reached the tap before stop) the file can end up missing or empty.
        // Returning nil surfaces the "Audio recording failed to save" path instead of
        // handing a stale URL to the transcription queue.
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? UInt64) ?? 0
        if attrs == nil {
            logger.error("Audio file missing on stop: \(url.lastPathComponent, privacy: .public)")
            return nil
        }
        if size == 0 {
            logger.error("Audio file empty on stop: \(url.lastPathComponent, privacy: .public)")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    // Runs `work` on the engine queue without blocking the caller's thread. If it doesn't
    // finish within `timeout` the caller gets `.startTimedOut`; should the work still
    // complete later, `discard` cleans up its result (e.g. stops a late-starting engine so
    // the microphone doesn't stay on unseen).
    private nonisolated static func onEngineQueue<T: Sendable>(
        timeout: Duration,
        discard: @escaping @Sendable (T) -> Void,
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            engineQueue.async {
                do {
                    let value = try work()
                    if !once.resume(with: .success(value)) { discard(value) }
                } catch {
                    once.resume(with: .failure(error))
                }
            }
            let (sec, atto) = timeout.components
            DispatchQueue.global().asyncAfter(deadline: .now() + Double(sec) + Double(atto) * 1e-18) {
                once.resume(with: .failure(AudioRecorderError.startTimedOut))
            }
        }
    }
}


// Streaming converter from the device's native format to whisper's 16 kHz mono.
// Only ever used from the tap's thread, one buffer at a time, hence @unchecked.
private nonisolated final class LiveResampler: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let inputRate: Double
    private let sink: LiveSampleSink

    init?(from inputFormat: AVAudioFormat, sink: LiveSampleSink) {
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { return nil }
        self.converter = converter
        self.outputFormat = outputFormat
        self.inputRate = inputFormat.sampleRate
        self.sink = sink
    }

    func push(_ buffer: AVAudioPCMBuffer) {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / inputRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        // .noDataNow (not .endOfStream) after the single buffer keeps the converter's
        // resampling state across calls, so there are no clicks at buffer boundaries.
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, statusPtr in
            if supplied {
                statusPtr.pointee = .noDataNow
                return nil
            }
            supplied = true
            statusPtr.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil,
              let channel = output.floatChannelData, output.frameLength > 0 else { return }
        sink.append(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }
}
