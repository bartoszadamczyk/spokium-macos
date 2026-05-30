import AppKit
import AudioToolbox

@MainActor
enum RecordingSounds {
    private static let startSoundID: SystemSoundID = loadSound(named: "Blow")
    private static let pasteSoundID: SystemSoundID = loadSound(named: "Frog")
    private static let emptySoundID: SystemSoundID = loadSound(named: "Funk")

    static var enabled: Bool {
        AppDefaults.playSounds
    }

    static func playStart() {
        guard enabled else { return }
        AudioServicesPlaySystemSound(startSoundID)
    }

    static func playPaste() {
        guard enabled else { return }
        AudioServicesPlaySystemSound(pasteSoundID)
    }

    static func playEmpty() {
        guard enabled else { return }
        AudioServicesPlaySystemSound(emptySoundID)
    }

    private static func loadSound(named name: String) -> SystemSoundID {
        let url = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
        var soundID: SystemSoundID = 0
        AudioServicesCreateSystemSoundID(url as CFURL, &soundID)
        return soundID
    }
}

