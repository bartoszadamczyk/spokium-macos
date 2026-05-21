import Foundation

enum ModelLocator {
    static var modelsDirectory: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Spokium/models", isDirectory: true)
    }

    static func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: modelsDirectory,
            withIntermediateDirectories: true
        )
    }

    static func migrateFromOldDirectory() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let fm = FileManager.default
        let candidates = ["spokium-macos", "vox-macos", "whisper-macos"]
        for parent in candidates {
            let oldDir = appSupport.appendingPathComponent("\(parent)/models", isDirectory: true)
            guard fm.fileExists(atPath: oldDir.path),
                  let files = try? fm.contentsOfDirectory(at: oldDir, includingPropertiesForKeys: nil) else { continue }
            try? ensureDirectoryExists()
            for file in files where file.pathExtension == "bin" {
                let dest = modelsDirectory.appendingPathComponent(file.lastPathComponent)
                if !fm.fileExists(atPath: dest.path) {
                    try? fm.moveItem(at: file, to: dest)
                }
            }
            try? fm.removeItem(at: oldDir)
            let oldParent = appSupport.appendingPathComponent(parent, isDirectory: true)
            if let remaining = try? fm.contentsOfDirectory(atPath: oldParent.path), remaining.isEmpty {
                try? fm.removeItem(at: oldParent)
            }
        }
    }

    static func availableModels() -> [URL] {
        try? ensureDirectoryExists()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: modelsDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return files
            .filter { $0.pathExtension == "bin" }
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
    }

    static func defaultModel() -> URL? {
        availableModels().first
    }
}
