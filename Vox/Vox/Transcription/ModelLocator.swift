import Foundation

enum ModelLocator {
    static var modelsDirectory: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("whisper-macos/models", isDirectory: true)
    }

    static func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: modelsDirectory,
            withIntermediateDirectories: true
        )
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
