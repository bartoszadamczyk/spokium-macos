import AVFoundation

enum AudioRecorderError: Error {
    case microphoneDenied
    case alreadyRunning
}

@MainActor
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var outputFile: AVAudioFile?

    var isRunning: Bool { engine.isRunning }

    func start(to fileURL: URL) async throws {
        guard !engine.isRunning else { throw AudioRecorderError.alreadyRunning }

        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else { throw AudioRecorderError.microphoneDenied }

        let inputNode = engine.inputNode
        let format = inputNode.inputFormat(forBus: 0)

        let file = try AVAudioFile(forWriting: fileURL, settings: format.settings)
        outputFile = file

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { @Sendable buffer, _ in
            try? file.write(from: buffer)
        }

        try engine.start()
    }

    func stop() -> URL? {
        guard engine.isRunning else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let url = outputFile?.url
        outputFile = nil
        return url
    }
}
