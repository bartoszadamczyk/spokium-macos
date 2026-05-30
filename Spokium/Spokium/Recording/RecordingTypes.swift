import Foundation

enum RecordingState: Equatable {
    case idle
    case starting
    case recording
    case finishing
}

enum RecordingError: Equatable {
    case noModel
    case microphoneDenied
    case recordingFailed(String)
    case transcriptionFailed(String)
    case downloadFailed(String)
    case noAccessibility

    var menuMessage: String {
        switch self {
        case .noModel: "No Whisper model selected"
        case .microphoneDenied: "Microphone access denied"
        case .recordingFailed: "Recording failed"
        case .transcriptionFailed: "Transcription failed"
        case .downloadFailed: "Model download failed"
        case .noAccessibility: "Paste blocked — Accessibility permission needed"
        }
    }
}

enum CompletionFeedback: Equatable {
    case pasted
    case copied
    case empty
    case failed(String)
}
