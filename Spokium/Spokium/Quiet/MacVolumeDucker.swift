import AudioToolbox
import CoreAudio
import Foundation
import OSLog

nonisolated enum MacVolumeMode: String, CaseIterable {
    case unchanged, lower, mute

    var title: String {
        switch self {
        case .unchanged: "Don't change"
        case .lower: "Lower to 20%"
        case .mute: "Mute"
        }
    }

    // Fraction of the current volume while recording.
    var factor: Float32 {
        switch self {
        case .unchanged: 1
        case .lower: 0.2
        case .mute: 0
        }
    }
}

// Lowers the Mac's output volume while recording and puts it back afterwards — via
// Core Audio, no permission needed. Safeguards:
//   - The original volume is saved before ducking and restored on the next launch if
//     the app died mid-recording (or the Mac slept and Spokium was quit).
//   - It's restored only if the volume is still what we set: a change the user made
//     meanwhile wins, like the clipboard restore.
//   - The device is remembered by UID, so switching outputs mid-recording restores the
//     right one.
//   - Outputs without a software volume (some HDMI/USB devices) are left alone.
enum MacVolumeDucker {
    private nonisolated struct Duck: Codable {
        let deviceUID: String
        let original: Float32
        let ducked: Float32
    }

    private static let logger = Logger(subsystem: "com.spokium.mac", category: "Quiet")

    static func duck() {
        restore()
        let mode = AppDefaults.macVolumeWhileRecording
        guard mode != .unchanged,
              let device = defaultOutputDevice(),
              let uid = deviceUID(device),
              isVolumeSettable(device),
              let original = volume(of: device), original > 0 else { return }
        let target = original * mode.factor
        // Saved before changing anything, so a crash right here is still repaired.
        save(Duck(deviceUID: uid, original: original, ducked: target))
        setVolume(target, on: device)
        // Devices round to their own volume steps; remember what was actually set, or
        // the "did the user change it?" check in restore() could misfire.
        let actual = volume(of: device) ?? target
        save(Duck(deviceUID: uid, original: original, ducked: actual))
        logger.info("Mac volume lowered: \(original) → \(actual)")
    }

    static func restore() {
        guard let duck = load() else { return }
        clear()
        guard let device = device(forUID: duck.deviceUID), let current = volume(of: device) else { return }
        guard abs(current - duck.ducked) < 0.02 else {
            logger.info("Mac volume changed during recording — leaving it")
            return
        }
        setVolume(duck.original, on: device)
        logger.info("Mac volume restored to \(duck.original)")
    }

    // MARK: Persistence

    private static func save(_ duck: Duck) {
        UserDefaults.standard.set(try? JSONEncoder().encode(duck), forKey: DefaultsKey.macVolumeDuck)
    }

    private static func load() -> Duck? {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.macVolumeDuck) else { return nil }
        return try? JSONDecoder().decode(Duck.self, from: data)
    }

    private static func clear() {
        UserDefaults.standard.removeObject(forKey: DefaultsKey.macVolumeDuck)
    }

    // MARK: Core Audio

    private static var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private static func defaultOutputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return nil }
        return device
    }

    private static func deviceUID(_ device: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
              let uid = value?.takeRetainedValue() else { return nil }
        return uid as String
    }

    private static func device(forUID uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID = uid as CFString
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { pointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), pointer, &size, &device
            )
        }
        return status == noErr && device != 0 ? device : nil
    }

    private static func isVolumeSettable(_ device: AudioObjectID) -> Bool {
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &volumeAddress, &settable) == noErr && settable.boolValue
    }

    private static func volume(of device: AudioObjectID) -> Float32? {
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &size, &volume) == noErr ? volume : nil
    }

    private static func setVolume(_ volume: Float32, on device: AudioObjectID) {
        var value = volume
        AudioObjectSetPropertyData(device, &volumeAddress, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }
}
