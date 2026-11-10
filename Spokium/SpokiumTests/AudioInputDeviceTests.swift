import Foundation
import Testing

@testable import Spokium

@MainActor
struct AudioInputDeviceTests {
    private func device(_ uid: String, _ connection: AudioInputDevice.Connection) -> AudioInputDevice {
        AudioInputDevice(deviceID: 0, name: uid, uid: uid, connection: connection)
    }

    private let airPods = AudioInputDevice(deviceID: 0, name: "AirPods", uid: "airpods", connection: .wireless)
    private let builtIn = AudioInputDevice(deviceID: 0, name: "MacBook", uid: "builtin", connection: .builtIn)
    private let usb = AudioInputDevice(deviceID: 0, name: "USB", uid: "usb", connection: .wired)
    private let blackHole = AudioInputDevice(deviceID: 0, name: "BlackHole", uid: "bh", connection: .virtual)

    @Test
    func builtInBeatsWiredBeatsWireless() {
        let all = [airPods, builtIn, usb]
        #expect(AudioInputDevice.nextBest(from: all, builtInUsable: true, systemDefaultUID: "airpods") == builtIn)
        #expect(AudioInputDevice.nextBest(from: [airPods, usb], builtInUsable: true, systemDefaultUID: "airpods") == usb)
    }

    @Test
    func lidClosed_prefersWiredOverWireless() {
        let all = [airPods, builtIn, usb]
        #expect(AudioInputDevice.nextBest(from: all, builtInUsable: false, systemDefaultUID: "airpods") == usb)
    }

    @Test
    func lidClosed_skipsBuiltIn() {
        #expect(AudioInputDevice.nextBest(from: [airPods, builtIn], builtInUsable: false, systemDefaultUID: nil) == airPods)
        #expect(AudioInputDevice.nextBest(from: [builtIn], builtInUsable: false, systemDefaultUID: nil) == nil)
    }

    @Test
    func virtualDevices_areNeverPicked() {
        #expect(AudioInputDevice.nextBest(from: [blackHole], builtInUsable: true, systemDefaultUID: "bh") == nil)
        #expect(AudioInputDevice.nextBest(from: [blackHole, airPods], builtInUsable: true, systemDefaultUID: "bh") == airPods)
    }

    @Test
    func tieGoesToSystemDefault_thenListOrder() {
        let other = device("usb2", .wired)
        #expect(AudioInputDevice.nextBest(from: [usb, other], builtInUsable: true, systemDefaultUID: "usb2") == other)
        #expect(AudioInputDevice.nextBest(from: [usb, other], builtInUsable: true, systemDefaultUID: "airpods") == usb)
    }
}

@MainActor
struct InputReplacementTests {
    private let airPods = AudioInputDevice(deviceID: 0, name: "AirPods", uid: "airpods", connection: .wireless)
    private let iPhone = AudioInputDevice(deviceID: 0, name: "iPhone", uid: "iphone", connection: .wireless)
    private let builtIn = AudioInputDevice(deviceID: 0, name: "MacBook", uid: "builtin", connection: .builtIn)
    private let usb = AudioInputDevice(deviceID: 0, name: "USB", uid: "usb", connection: .wired)

    @Test
    func selectedDeviceGone_switchesToNextBest() {
        let next = AudioInputDevice.replacementSelection(
            selectedUID: "usb", devices: [iPhone, builtIn], systemDefaultUID: "iphone", builtInUsable: true)
        #expect(next == "builtin")
    }

    @Test
    func selectedDeviceStillThere_isLeftAlone() {
        let next = AudioInputDevice.replacementSelection(
            selectedUID: "usb", devices: [usb, builtIn], systemDefaultUID: "builtin", builtInUsable: true)
        #expect(next == nil)
    }

    @Test
    func systemDefault_fellBackToSomethingWorse_switchesToBetter() {
        // AirPods disconnected, macOS picked the iPhone although the built-in mic is there.
        let next = AudioInputDevice.replacementSelection(
            selectedUID: "", devices: [iPhone, builtIn], systemDefaultUID: "iphone", builtInUsable: true)
        #expect(next == "builtin")
    }

    @Test
    func systemDefault_fellBackToTheBestAvailable_staysSystemDefault() {
        let next = AudioInputDevice.replacementSelection(
            selectedUID: "", devices: [airPods, builtIn], systemDefaultUID: "builtin", builtInUsable: true)
        #expect(next == nil)
    }

    @Test
    func nothingLeft_fallsBackToSystemDefault() {
        let next = AudioInputDevice.replacementSelection(
            selectedUID: "usb", devices: [], systemDefaultUID: nil, builtInUsable: true)
        #expect(next == "")
    }
}

@MainActor
struct LanguageMenuOrderTests {
    @Test
    func englishFirst_thenAlphabetical() {
        let names = WhisperLanguage.menuOrder.map(\.displayName)
        #expect(names.first == "English")
        let rest = Array(names.dropFirst())
        #expect(rest == rest.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        #expect(names.count == WhisperLanguage.all.count)
    }
}
