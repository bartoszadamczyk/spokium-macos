import Foundation
import Testing

@testable import Spokium

@MainActor
struct AppDefaultsTests {
    @Test
    func maxRecordingMinutes_currentOptionsAreKept() {
        for option in AppDefaults.maxRecordingMinutesOptions {
            #expect(AppDefaults.normalizedMaxRecordingMinutes(option) == option)
        }
        #expect(AppDefaults.normalizedMaxRecordingMinutes(0) == 0)
    }

    @Test
    func maxRecordingMinutes_oldShortValuesMoveUpToTenMinutes() {
        #expect(AppDefaults.normalizedMaxRecordingMinutes(1) == 10)
        #expect(AppDefaults.normalizedMaxRecordingMinutes(2) == 10)
        #expect(AppDefaults.normalizedMaxRecordingMinutes(5) == 10)
    }

    @Test
    func maxRecordingMinutes_inBetweenAndHugeValuesSnapToAnOption() {
        #expect(AppDefaults.normalizedMaxRecordingMinutes(15) == 20)
        #expect(AppDefaults.normalizedMaxRecordingMinutes(45) == 60)
        #expect(AppDefaults.normalizedMaxRecordingMinutes(120) == 60)
    }

    @Test
    func maxRecordingMinutes_defaultIsThirtyMinutes() {
        #expect(AppDefaults.maxRecordingMinutesDefault == 30)
    }

    @Test
    func soundEffects_areOnByDefault() {
        #expect(AppDefaults.playSoundsDefault == true)
    }

    @Test
    func recentTranscripts_areKeptByDefault() {
        #expect(AppDefaults.keepRecentTranscriptsDefault == true)
    }

    @Test
    func dictionary_defaultsToExampleEntry() {
        #expect(AppDefaults.dictionaryEntriesDefault == "Spokium")
    }

    @Test
    func lowerMacVolume_carriesOver153Choices() {
        let key = DefaultsKey.macVolumeWhileRecording
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        for (stored, expected) in [("lower", true), ("mute", true), ("unchanged", false)] {
            UserDefaults.standard.set(stored, forKey: key)
            #expect(AppDefaults.lowerMacVolumeWhileRecording == expected, "\(stored)")
        }
        UserDefaults.standard.removeObject(forKey: key)
        #expect(!AppDefaults.lowerMacVolumeWhileRecording)
        AppDefaults.lowerMacVolumeWhileRecording = true
        #expect(AppDefaults.lowerMacVolumeWhileRecording)
    }
}
