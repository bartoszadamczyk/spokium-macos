import Foundation

extension Notification.Name {
    // A Neural Engine encoder was marked unusable on this Mac, or the mark was cleared.
    nonisolated static let coreMLHealthChanged = Notification.Name("SpokiumCoreMLHealthChanged")
}

// Remembers Neural Engine encoders that never finished loading here. Seen on an M1 Pro
// with large-v3: aned compiled for well over the time limit and never returned, so every
// dictation waited forever. A marked model is loaded GPU-only on later launches.
nonisolated enum CoreMLHealth {
    static let loadLimit: Duration = .seconds(600)

    static func stem(of modelURL: URL) -> String {
        modelURL.deletingPathExtension().lastPathComponent
    }

    static func isUnusable(_ modelURL: URL) -> Bool {
        AppDefaults.coreMLUnusableModels.contains(stem(of: modelURL))
    }

    static func markUnusable(_ modelURL: URL) {
        var stems = AppDefaults.coreMLUnusableModels
        guard !stems.contains(stem(of: modelURL)) else { return }
        stems.append(stem(of: modelURL))
        AppDefaults.coreMLUnusableModels = stems
        NotificationCenter.default.post(name: .coreMLHealthChanged, object: modelURL)
    }

    // The user's choice in Settings → Model, independent of the health mark.
    static func isDisabledByUser(_ modelURL: URL) -> Bool {
        AppDefaults.coreMLDisabledModels.contains(stem(of: modelURL))
    }

    static func setEnabledByUser(_ enabled: Bool, _ modelURL: URL) {
        var stems = AppDefaults.coreMLDisabledModels.filter { $0 != stem(of: modelURL) }
        if !enabled { stems.append(stem(of: modelURL)) }
        AppDefaults.coreMLDisabledModels = stems
    }

    // Load the model without its encoder: switched off, or marked unusable.
    static func loadGPUOnly(_ modelURL: URL) -> Bool {
        isDisabledByUser(modelURL) || isUnusable(modelURL)
    }

    static func clear(_ modelURL: URL) {
        let stems = AppDefaults.coreMLUnusableModels.filter { $0 != stem(of: modelURL) }
        guard stems.count != AppDefaults.coreMLUnusableModels.count else { return }
        AppDefaults.coreMLUnusableModels = stems
        NotificationCenter.default.post(name: .coreMLHealthChanged, object: modelURL)
    }
}
