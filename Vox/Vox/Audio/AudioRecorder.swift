@preconcurrency import AVFoundation
import AudioToolbox
import OSLog

enum AudioRecorderError: Error {
    case microphoneDenied
    case alreadyRunning
    case writeFailed
}

private final class WriteErrorFlag: @unchecked Sendable {
    nonisolated(unsafe) var failed = false
}

private final class AudioLevelMeter: @unchecked Sendable {
    nonisolated(unsafe) var level: Float = 0
}

@MainActor
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var outputFile: AVAudioFile?
    private let writeErrorFlag = WriteErrorFlag()
    private let levelMeter = AudioLevelMeter()
    private let logger = Logger(subsystem: "com.bartoszadamczyk.Vox", category: "AudioRecorder")

    var isRunning: Bool { engine.isRunning }
    var currentLevel: Float { levelMeter.level }

    func start(to fileURL: URL) async throws {
        guard !engine.isRunning else { throw AudioRecorderError.alreadyRunning }

        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else { throw AudioRecorderError.microphoneDenied }

        let inputNode = engine.inputNode
        if let uid = UserDefaults.standard.string(forKey: "selectedInputDevice"),
           !uid.isEmpty,
           let device = AudioInputDevice.available().first(where: { $0.uid == uid }),
           let audioUnit = inputNode.audioUnit {
            var deviceID = device.deviceID
            AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }
        let format = inputNode.inputFormat(forBus: 0)

        let file = try AVAudioFile(forWriting: fileURL, settings: format.settings)
        outputFile = file
        writeErrorFlag.failed = false
        levelMeter.level = 0

        let flag = writeErrorFlag
        let meter = levelMeter
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { @Sendable buffer, _ in
            do {
                try file.write(from: buffer)
            } catch {
                flag.failed = true
            }

            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { return }
            var sum: Float = 0
            for i in 0..<frameLength {
                sum += channelData[i] * channelData[i]
            }
            meter.level = (sum / Float(frameLength)).squareRoot()
        }

        try engine.start()
    }

    func stop() -> URL? {
        guard engine.isRunning else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let url = outputFile?.url
        outputFile = nil
        if writeErrorFlag.failed {
            logger.error("Audio write errors occurred during recording")
            return nil
        }
        return url
    }
}
