import Foundation

// Centralised UserDefaults keys. Use these everywhere instead of string literals
// — typos become compile errors. Also serves as the canonical list of every
// persisted setting (see also `Snippets` and `ModelPerformanceStore` which own
// their own JSON-encoded entries under the `snippets` and `modelPerformance`
// keys here).
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
    static let maxRecordingMinutes = "maxRecordingMinutes"
    static let modelPerformance = "modelPerformance"
    static let keepRecentTranscripts = "keepRecentTranscripts"
    // Hidden developer toggle. No UI surface — enable via terminal:
    //   defaults write com.spokium.mac debugMode -bool true
    static let debugMode = "debugMode"
}

// Typed read/write accessors for everything in `DefaultsKey`. Pure functions over
// `UserDefaults.standard` — no caching, every access re-reads. Keeping the layer
// nonisolated so it's callable from actors and tests without ceremony.
nonisolated enum AppDefaults {
    // Default values used when the key is unset. Listed at the top so they're
    // easy to find/change without grepping for the access site.
    static let selectedLanguageDefault = "auto"
    static let paragraphSplittingDefault = true
    static let silenceThresholdDefault: Double = 3.0
    static let autoPasteDefault = true
    static let preserveClipboardDefault = true
    static let dictionaryEntriesDefault = ""
    static let selectedInputDeviceDefault = ""
    static let pushToRecordDefault = false
    static let playSoundsDefault = false
    static let keepRecentTranscriptsDefault = false
    static let maxRecordingMinutesDefault: Double = 10.0

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

    static var selectedInputDevice: String {
        get { store.string(forKey: DefaultsKey.selectedInputDevice) ?? selectedInputDeviceDefault }
        set { store.set(newValue, forKey: DefaultsKey.selectedInputDevice) }
    }

    static var pushToRecord: Bool {
        get { store.bool(forKey: DefaultsKey.pushToRecord) }
        set { store.set(newValue, forKey: DefaultsKey.pushToRecord) }
    }

    static var playSounds: Bool {
        get { store.bool(forKey: DefaultsKey.playSounds) }
        set { store.set(newValue, forKey: DefaultsKey.playSounds) }
    }

    static var keepRecentTranscripts: Bool {
        get { store.bool(forKey: DefaultsKey.keepRecentTranscripts) }
        set { store.set(newValue, forKey: DefaultsKey.keepRecentTranscripts) }
    }

    static var maxRecordingMinutes: Double {
        get { store.object(forKey: DefaultsKey.maxRecordingMinutes) as? Double ?? maxRecordingMinutesDefault }
        set { store.set(newValue, forKey: DefaultsKey.maxRecordingMinutes) }
    }

    // Read-only on purpose. Not exposed in Settings; enable via terminal:
    //   defaults write com.spokium.mac debugMode -bool true
    static var debugMode: Bool {
        store.bool(forKey: DefaultsKey.debugMode)
    }
}
