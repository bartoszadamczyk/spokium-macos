@preconcurrency import AVFoundation
import AudioToolbox
import OSLog
import Synchronization

enum AudioRecorderError: Error {
    case microphoneDenied
    case alreadyRunning
    case writeFailed
}

private final class WriteErrorFlag: Sendable {
    let failed = Atomic<Bool>(false)
}

private nonisolated final class AudioLevelMeter: Sendable {
    private let bits = Atomic<UInt32>(0)
    var level: Float { Float(bitPattern: bits.load(ordering: .relaxed)) }
    func store(_ value: Float) { bits.store(value.bitPattern, ordering: .relaxed) }
    func reset() { bits.store(0, ordering: .relaxed) }
}

@MainActor
final class AudioRecorder {
    private var engine = AVAudioEngine()
    private var outputFile: AVAudioFile?
    private let writeErrorFlag = WriteErrorFlag()
    private let levelMeter = AudioLevelMeter()
    private var configChangeObserver: NSObjectProtocol?
    private let logger = Logger(subsystem: "com.bartoszadamczyk.Spokium", category: "AudioRecorder")

    var onConfigurationChange: (@MainActor () -> Void)?

    var isRunning: Bool { engine.isRunning }
    var currentLevel: Float { levelMeter.level }

    func start(to fileURL: URL) async throws {
        guard !engine.isRunning else { throw AudioRecorderError.alreadyRunning }

        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else { throw AudioRecorderError.microphoneDenied }

        engine = AVAudioEngine()
        let inputNode = engine.inputNode
        if let uid = UserDefaults.standard.string(forKey: "selectedInputDevice"),
           !uid.isEmpty {
            if let device = AudioInputDevice.available().first(where: { $0.uid == uid }),
               let audioUnit = inputNode.audioUnit {
                var deviceID = device.deviceID
                let status = AudioUnitSetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &deviceID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                if status != noErr {
                    logger.error("Failed to apply selected input device \(uid, privacy: .public) (OSStatus \(status)) — falling back to system default")
                }
            } else {
                logger.error("Selected input device \(uid, privacy: .public) not available — falling back to system default")
            }
        }
        let format = inputNode.inputFormat(forBus: 0)

        let file = try AVAudioFile(forWriting: fileURL, settings: format.settings)
        outputFile = file
        writeErrorFlag.failed.store(false, ordering: .relaxed)
        levelMeter.reset()

        let flag = writeErrorFlag
        let meter = levelMeter
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { @Sendable buffer, _ in
            do {
                try file.write(from: buffer)
            } catch {
                flag.failed.store(true, ordering: .relaxed)
            }

            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { return }
            var sum: Float = 0
            for i in 0..<frameLength {
                sum += channelData[i] * channelData[i]
            }
            meter.store((sum / Float(frameLength)).squareRoot())
        }

        let startInstant = ContinuousClock.now
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if ContinuousClock.now - startInstant < .seconds(2) { return }
                self.onConfigurationChange?()
            }
        }

        try engine.start()
    }

    func stop() -> URL? {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        let wasRunning = engine.isRunning
        engine.inputNode.removeTap(onBus: 0)
        if wasRunning {
            engine.stop()
        }
        let url = outputFile?.url
        outputFile = nil
        guard wasRunning else { return nil }
        if writeErrorFlag.failed.load(ordering: .relaxed) {
            logger.error("Audio write errors occurred during recording")
            return nil
        }
        return url
    }
}
