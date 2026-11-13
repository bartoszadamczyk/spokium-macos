import CoreAudio
import CoreGraphics
import Foundation

extension Notification.Name {
    // A device was added or removed; the selection may have been re-pointed.
    static let audioInputDevicesChanged = Notification.Name("SpokiumAudioInputDevicesChanged")
}

struct AudioInputDevice: Equatable {
    enum Connection: Int, Comparable {
        case builtIn, wired, wireless, virtual

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let deviceID: AudioDeviceID
    let name: String
    let uid: String
    var connection: Connection = .wired

    static func available() -> [AudioInputDevice] {
        AudioInputDeviceCache.shared.devices
    }

    // The replacement when an input disappears. The built-in mic first, then wired (USB,
    // Thunderbolt…), then wireless — Bluetooth headphones drop into low-quality call mode
    // when recorded from, and an iPhone (Continuity) mic is a worse pick than the Mac's own.
    // With the lid closed the built-in mic is off, so it's skipped and wired comes first. Virtual devices (BlackHole, Zoom…)
    // are never picked. Ties go to the macOS default input, then list order.
    static func nextBest(
        from devices: [AudioInputDevice],
        builtInUsable: Bool,
        systemDefaultUID: String?
    ) -> AudioInputDevice? {
        let candidates = devices.filter {
            $0.connection != .virtual && ($0.connection != .builtIn || builtInUsable)
        }
        guard let best = candidates.map(\.connection).min() else { return nil }
        let tier = candidates.filter { $0.connection == best }
        return tier.first { $0.uid == systemDefaultUID } ?? tier.first
    }

    static func nextBest() -> AudioInputDevice? {
        nextBest(from: available(), builtInUsable: !isLidClosed, systemDefaultUID: defaultInputUID())
    }

    // After a device was removed: the selection to switch to, or nil to leave it alone.
    // A selected device that's gone → the next best one. "System Default" stays unless
    // macOS fell back to something worse than the next best (e.g. AirPods gone, macOS
    // picks the iPhone while the built-in mic is there). The switch is written to the
    // setting, so the menu shows what will be recorded from and the user can correct it.
    static func replacementSelection(
        selectedUID: String,
        devices: [AudioInputDevice],
        systemDefaultUID: String?,
        builtInUsable: Bool
    ) -> String? {
        let best = nextBest(from: devices, builtInUsable: builtInUsable, systemDefaultUID: systemDefaultUID)
        if !selectedUID.isEmpty {
            guard !devices.contains(where: { $0.uid == selectedUID }) else { return nil }
            return best?.uid ?? ""
        }
        guard let best, best.uid != systemDefaultUID else { return nil }
        let current = devices.first { $0.uid == systemDefaultUID }
        return current.map { best.connection < $0.connection } ?? true ? best.uid : nil
    }

    // Approximation: in clamshell mode the internal display goes offline. Desktops have
    // no internal display, but they have no built-in mic either (the iMac's display is
    // internal, so it counts as open).
    static var isLidClosed: Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return false }
        let hasInternal = ids.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) != 0 }
        return !hasInternal && hasBuiltInInput
    }

    private static var hasBuiltInInput: Bool {
        available().contains { $0.connection == .builtIn }
    }

    static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids
    }

    static func defaultInputName() -> String? {
        guard let id = defaultInputDeviceID() else { return nil }
        return stringProperty(kAudioObjectPropertyName, of: id)
    }

    static func defaultInputUID() -> String? {
        guard let id = defaultInputDeviceID() else { return nil }
        return stringProperty(kAudioDevicePropertyDeviceUID, of: id)
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr else { return nil }
        return deviceID
    }

    static func deviceFromID(_ id: AudioDeviceID) -> AudioInputDevice? {
        guard !isHidden(id), !isAggregate(id), hasInputStreams(id) else { return nil }
        guard let name = stringProperty(kAudioObjectPropertyName, of: id),
              let uid = stringProperty(kAudioDevicePropertyDeviceUID, of: id) else { return nil }
        return AudioInputDevice(deviceID: id, name: name, uid: uid, connection: connection(of: id))
    }

    private static func connection(of id: AudioDeviceID) -> Connection {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport) == noErr else { return .virtual }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            return .builtIn
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeFireWire, kAudioDeviceTransportTypePCI,
             kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypeHDMI,
             kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeAVB:
            return .wired
        // An iPhone counts as wireless even over a cable: it's still a phone mic.
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE,
             kAudioDeviceTransportTypeAirPlay, kAudioDeviceTransportTypeContinuityCaptureWireless,
             kAudioDeviceTransportTypeContinuityCaptureWired:
            return .wireless
        default:
            return .virtual
        }
    }

    private static func isHidden(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIsHidden,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var hidden: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &hidden) == noErr else { return false }
        return hidden != 0
    }

    private static func isAggregate(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyClass,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var classID: AudioClassID = 0
        var size = UInt32(MemoryLayout<AudioClassID>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &classID) == noErr else { return false }
        return classID == kAudioAggregateDeviceClassID
    }

    // Only counts the input streams. Reading their format (kAudioDevicePropertyStreamConfiguration)
    // is the kind of query that can wake a Bluetooth headset's mic side and switch it into
    // call mode, so it isn't done here.
    private static func hasInputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let cfString = value?.takeRetainedValue() else { return nil }
        return cfString as String
    }
}

// Probing every device's properties on each menu open was enough to flip Bluetooth
// headphones into call mode while music played. The list is re-probed only when the bare
// device-ID list changes (cheap to read, touches no device). CoreAudio's device-list
// callback is forwarded as .audioInputDevicesChanged with the removed devices.
final class AudioInputDeviceCache {
    static let shared = AudioInputDeviceCache()

    private var ids: [AudioDeviceID]?
    private var cached: [AudioInputDevice] = []
    private var isListening = false

    func startListening() {
        guard !isListening else { return }
        isListening = true
        _ = devices
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in
            MainActor.assumeIsolated {
                let cache = AudioInputDeviceCache.shared
                let before = cache.cached
                let after = cache.devices
                let removed = before.filter { old in !after.contains { $0.uid == old.uid } }
                NotificationCenter.default.post(name: .audioInputDevicesChanged, object: removed)
            }
        }
    }

    var devices: [AudioInputDevice] {
        let current = AudioInputDevice.deviceIDs()
        if current != ids {
            ids = current
            cached = current.compactMap(AudioInputDevice.deviceFromID)
        }
        return cached
    }
}
