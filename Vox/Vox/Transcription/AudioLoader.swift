@preconcurrency import AVFoundation

enum AudioLoaderError: Error {
    case unsupportedFormat
    case readFailed
}

enum AudioLoader {
    nonisolated static func loadResampled(url: URL) throws -> [Float] {
        let inputFile = try AVAudioFile(forReading: url)
        let inputFormat = inputFile.processingFormat

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioLoaderError.unsupportedFormat
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioLoaderError.unsupportedFormat
        }

        let inputFrames = AVAudioFrameCount(inputFile.length)
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: inputFrames
        ) else {
            throw AudioLoaderError.unsupportedFormat
        }
        try inputFile.read(into: inputBuffer)

        let outputCapacity = AVAudioFrameCount(
            Double(inputFrames) * 16_000.0 / inputFormat.sampleRate
        ) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputCapacity
        ) else {
            throw AudioLoaderError.unsupportedFormat
        }

        nonisolated(unsafe) let consumed = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
        consumed.initialize(to: false)
        defer { consumed.deallocate() }

        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, statusPtr in
            if consumed.pointee {
                statusPtr.pointee = .endOfStream
                return nil
            }
            consumed.pointee = true
            statusPtr.pointee = .haveData
            return inputBuffer
        }

        if let error { throw error }
        guard status != .error else { throw AudioLoaderError.readFailed }

        guard let channelData = outputBuffer.floatChannelData else {
            throw AudioLoaderError.unsupportedFormat
        }
        let count = Int(outputBuffer.frameLength)
        return Array(UnsafeBufferPointer(start: channelData[0], count: count))
    }
}
