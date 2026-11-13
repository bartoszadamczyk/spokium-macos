import Foundation

// Centralised UserDefaults keys. Use these everywhere instead of string literals
// — typos become compile errors. Also serves as the canonical list of every
// persisted setting (see also `Snippets`, `ModelPerformanceStore` and
// `LanguageUsageStore`, which own their own JSON-encoded entries under the
// `snippets`, `modelPerformance` and `languageUsage` keys here).
nonisolated enum DefaultsKey {
    static let selectedLanguage = "selectedLanguage"
    static let paragraphSplitting = "paragraphSplitting"
    static let silenceThreshold = "silenceThreshold"
    static let autoPaste = "autoPaste"
    static let preserveClipboard = "preserveClipboard"
    static let dictionaryEntries = "dictionaryEntries"
    static let selectedModel = "selectedModel"
    static let selectedInputDevice = "selectedInputDevice"
    static let pushToRecord = "pushToRecord"
    static let playSounds = "playSounds"
    static let snippets = "snippets"
    static let quietEndpoints = "quietEndpoints"
    // 1.5.3 stored "unchanged" / "lower" / "mute" here; now a Bool ("lower or not").
    static let macVolumeWhileRecording = "macVolumeWhileRecording"
    // Volume to put back after a duck; present only while one is in effect, so a crash
    // mid-recording is repaired on the next launch.
    static let macVolumeDuck = "macVolumeDuck"
    // Model stems whose Neural Engine encoder never finished loading on this Mac.
    static let coreMLUnusableModels = "coreMLUnusableModels"
    static let selectedQuietEndpoint = "selectedQuietEndpoint"
    static let maxRecordingMinutes = "maxRecordingMinutes"
    static let modelPerformance = "modelPerformance"
    static let keepRecentTranscripts = "keepRecentTranscripts"
    static let liveTranscription = "liveTranscription"
    static let autoDetectLanguages = "autoDetectLanguages"
    static let languageUsage = "languageUsage"
    // Hidden developer toggle. No UI surface — enable via terminal:
    //   defaults write com.spokium.mac debugMode -bool true
    static let debugMode = "debugMode"
    // Hidden A/B switch for live chunking: Silero VAD (default) vs. the old RMS check.
    //   defaults write com.spokium.mac voiceActivityDetection -bool false
    static let voiceActivityDetection = "voiceActivityDetection"
}

// Typed read/write accessors for everything in `DefaultsKey`. Pure functions over
// `UserDefaults.standard` — no caching, every access re-reads. Keeping the layer
// nonisolated so it's callable from actors and tests without ceremony.
nonisolated enum AppDefaults {
    // Default values used when the key is unset. Listed at the top so they're
    // easy to find/change without grepping for the access site.
    static let selectedLanguageDefault = "auto"
    static let paragraphSplittingDefault = true
    static let silenceThresholdDefault: Double = 4.0
    static let autoPasteDefault = true
    static let preserveClipboardDefault = true
    // An example entry so the empty tab shows how it works.
    static let dictionaryEntriesDefault = "Spokium"
    static let selectedInputDeviceDefault = ""
    static let selectedQuietEndpointDefault = ""
    static let lowerMacVolumeWhileRecordingDefault = false
    static let pushToRecordDefault = false
    static let playSoundsDefault = true
    static let keepRecentTranscriptsDefault = true
    static let maxRecordingMinutesDefault: Double = 30.0
    // 0 = no limit. Earlier versions offered 1/2/5 minutes; those are mapped up to the
    // nearest current option (see normalizedMaxRecordingMinutes).
    static let maxRecordingMinutesOptions: [Double] = [10, 20, 30, 60]
    static let liveTranscriptionDefault = true
    // Comma-separated whisper language codes; empty means "any language".
    static let autoDetectLanguagesDefault = ""

    private static var store: UserDefaults { .standard }

    static var selectedLanguage: String {
        get { store.string(forKey: DefaultsKey.selectedLanguage) ?? selectedLanguageDefault }
        set { store.set(newValue, forKey: DefaultsKey.selectedLanguage) }
    }

    static var paragraphSplitting: Bool {
        get { store.object(forKey: DefaultsKey.paragraphSplitting) as? Bool ?? paragraphSplittingDefault }
        set { store.set(newValue, forKey: DefaultsKey.paragraphSplitting) }
    }

    static var silenceThreshold: Double {
        get { store.object(forKey: DefaultsKey.silenceThreshold) as? Double ?? silenceThresholdDefault }
        set { store.set(newValue, forKey: DefaultsKey.silenceThreshold) }
    }

    static var autoPaste: Bool {
        get { store.object(forKey: DefaultsKey.autoPaste) as? Bool ?? autoPasteDefault }
        set { store.set(newValue, forKey: DefaultsKey.autoPaste) }
    }

    static var preserveClipboard: Bool {
        get { store.object(forKey: DefaultsKey.preserveClipboard) as? Bool ?? preserveClipboardDefault }
        set { store.set(newValue, forKey: DefaultsKey.preserveClipboard) }
    }

    static var dictionaryEntries: String {
        get { store.string(forKey: DefaultsKey.dictionaryEntries) ?? dictionaryEntriesDefault }
        set { store.set(newValue, forKey: DefaultsKey.dictionaryEntries) }
    }

    // selectedModel has no static default — it's computed dynamically in
    // `ModelManager.init` based on what's actually downloaded. Return nil when
    // unset so callers can decide on a fallback.
    static var selectedModel: String? {
        get { store.string(forKey: DefaultsKey.selectedModel) }
        set { store.set(newValue, forKey: DefaultsKey.selectedModel) }
    }

    static var coreMLUnusableModels: [String] {
        get { store.stringArray(forKey: DefaultsKey.coreMLUnusableModels) ?? [] }
        set { store.set(newValue, forKey: DefaultsKey.coreMLUnusableModels) }
    }

    static var lowerMacVolumeWhileRecording: Bool {
        get {
            switch store.object(forKey: DefaultsKey.macVolumeWhileRecording) {
            case let on as Bool: on
            case let legacy as String: legacy == "lower" || legacy == "mute"
            default: lowerMacVolumeWhileRecordingDefault
            }
        }
        set { store.set(newValue, forKey: DefaultsKey.macVolumeWhileRecording) }
    }

    // QuietEndpoint.id as a string; "" = none.
    static var selectedQuietEndpoint: String {
        get { store.string(forKey: DefaultsKey.selectedQuietEndpoint) ?? selectedQuietEndpointDefault }
        set { store.set(newValue, forKey: DefaultsKey.selectedQuietEndpoint) }
    }

    static var selectedInputDevice: String {
        get { store.string(forKey: DefaultsKey.selectedInputDevice) ?? selectedInputDeviceDefault }
        set { store.set(newValue, forKey: DefaultsKey.selectedInputDevice) }
    }

    static var pushToRecord: Bool {
        get { store.bool(forKey: DefaultsKey.pushToRecord) }
        set { store.set(newValue, forKey: DefaultsKey.pushToRecord) }
    }

    static var playSounds: Bool {
        get { store.object(forKey: DefaultsKey.playSounds) as? Bool ?? playSoundsDefault }
        set { store.set(newValue, forKey: DefaultsKey.playSounds) }
    }

    static var keepRecentTranscripts: Bool {
        get { store.object(forKey: DefaultsKey.keepRecentTranscripts) as? Bool ?? keepRecentTranscriptsDefault }
        set { store.set(newValue, forKey: DefaultsKey.keepRecentTranscripts) }
    }

    static var maxRecordingMinutes: Double {
        get { normalizedMaxRecordingMinutes(store.object(forKey: DefaultsKey.maxRecordingMinutes) as? Double ?? maxRecordingMinutesDefault) }
        set { store.set(newValue, forKey: DefaultsKey.maxRecordingMinutes) }
    }

    static var liveTranscription: Bool {
        get { store.object(forKey: DefaultsKey.liveTranscription) as? Bool ?? liveTranscriptionDefault }
        set { store.set(newValue, forKey: DefaultsKey.liveTranscription) }
    }

    static var autoDetectLanguages: [String] {
        get {
            (store.string(forKey: DefaultsKey.autoDetectLanguages) ?? autoDetectLanguagesDefault)
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        set { store.set(newValue.joined(separator: ","), forKey: DefaultsKey.autoDetectLanguages) }
    }

    static func normalizedMaxRecordingMinutes(_ minutes: Double) -> Double {
        guard minutes > 0 else { return 0 }
        return maxRecordingMinutesOptions.first { $0 >= minutes } ?? maxRecordingMinutesOptions.last ?? minutes
    }

    // Read-only on purpose. Not exposed in Settings; enable via terminal:
    //   defaults write com.spokium.mac debugMode -bool true
    static var debugMode: Bool {
        store.bool(forKey: DefaultsKey.debugMode)
    }

    static var voiceActivityDetection: Bool {
        store.object(forKey: DefaultsKey.voiceActivityDetection) as? Bool ?? true
    }
}
