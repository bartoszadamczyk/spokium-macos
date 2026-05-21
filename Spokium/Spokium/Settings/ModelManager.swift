import CommonCrypto
import Foundation
import os
import OSLog

struct WhisperModel: Identifiable, Equatable {
    let name: String
    let displayName: String
    let sizeLabel: String
    let qualityNote: String
    let fileName: String
    let expectedSHA1: String

    var id: String { name }

    var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!
    }

    var localURL: URL {
        ModelLocator.modelsDirectory.appendingPathComponent(fileName)
    }

    static let all: [WhisperModel] = [
        WhisperModel(
            name: "tiny", displayName: "Tiny",
            sizeLabel: "~78 MB", qualityNote: "Fastest, lower accuracy",
            fileName: "ggml-tiny.bin",
            expectedSHA1: "bd577a113a864445d4c299885e0cb97d4ba92b5f"
        ),
        WhisperModel(
            name: "base", displayName: "Base",
            sizeLabel: "~148 MB", qualityNote: "Good balance for short dictation",
            fileName: "ggml-base.bin",
            expectedSHA1: "465707469ff3a37a2b9b8d8f89f2f99de7299dac"
        ),
        WhisperModel(
            name: "small", displayName: "Small",
            sizeLabel: "~488 MB", qualityNote: "Better accuracy, still fast on Apple Silicon",
            fileName: "ggml-small.bin",
            expectedSHA1: "55356645c2b361a969dfd0ef2c5a50d530afd8d5"
        ),
        WhisperModel(
            name: "medium", displayName: "Medium",
            sizeLabel: "~1.5 GB", qualityNote: "High accuracy, slower",
            fileName: "ggml-medium.bin",
            expectedSHA1: "fd9727b6e1217c2f614f9b698455c4ffd82463b4"
        ),
        WhisperModel(
            name: "large-v3", displayName: "Large v3",
            sizeLabel: "~3.1 GB", qualityNote: "Best accuracy",
            fileName: "ggml-large-v3.bin",
            expectedSHA1: "ad82bf6a9043ceed055076d0fd39f5f186ff8062"
        ),
        WhisperModel(
            name: "large-v3-turbo", displayName: "Large v3 Turbo",
            sizeLabel: "~1.6 GB", qualityNote: "Near-best accuracy, much faster",
            fileName: "ggml-large-v3-turbo.bin",
            expectedSHA1: "4af2b29d7ec73d781377bfd1758ca957a807e941"
        ),
    ]

    nonisolated static func validateFile(at url: URL, expectedSHA1: String) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        guard let magicData = try handle.read(upToCount: 4), magicData.count == 4 else {
            throw ModelValidationError.notGGML
        }
        let magic = magicData.withUnsafeBytes { $0.load(as: UInt32.self) }
        let validMagic: Set<UInt32> = [0x67676D6C, 0x67676D66, 0x67676A74]
        if !validMagic.contains(magic) {
            throw ModelValidationError.notGGML
        }

        try handle.seek(toOffset: 0)
        var context = CC_SHA1_CTX()
        CC_SHA1_Init(&context)
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            chunk.withUnsafeBytes { ptr in
                _ = CC_SHA1_Update(&context, ptr.baseAddress, CC_LONG(ptr.count))
            }
        }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        CC_SHA1_Final(&digest, &context)
        let actualSHA1 = digest.map { String(format: "%02x", $0) }.joined()

        if actualSHA1 != expectedSHA1 {
            throw ModelValidationError.checksumMismatch(expected: expectedSHA1, actual: actualSHA1)
        }
    }
}

private nonisolated final class DownloadTaskHolder: Sendable {
    private struct State {
        var task: URLSessionDownloadTask?
        var cancelled = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func register(_ task: URLSessionDownloadTask) {
        let cancelled = state.withLock { state -> Bool in
            state.task = task
            return state.cancelled
        }
        if cancelled { task.cancel() }
    }

    func cancel() {
        let task = state.withLock { state -> URLSessionDownloadTask? in
            state.cancelled = true
            return state.task
        }
        task?.cancel()
    }
}

enum ModelValidationError: LocalizedError {
    case notGGML
    case checksumMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .notGGML:
            return "File is not a valid GGML model — it may be an error page or corrupted download"
        case .checksumMismatch:
            return "SHA-1 checksum mismatch — the download may be corrupted or incomplete"
        }
    }
}

@Observable
@MainActor
final class ModelManager {
    private(set) var downloads: [String: Double] = [:]
    private(set) var downloadedNames: Set<String>
    private(set) var lastDownloadError: String?
    private(set) var verification: VerificationState = .idle

    enum VerificationState: Equatable {
        case idle
        case running
        case finished(passed: [String], failed: [String])
    }
    var selectedModelName: String {
        didSet { UserDefaults.standard.set(selectedModelName, forKey: "selectedModel") }
    }

    private let logger = Logger(subsystem: "com.bartoszadamczyk.Spokium", category: "ModelManager")
    private var activeTasks: [String: Task<Void, Never>] = [:]
    private var activeDownloadTasks: [String: URLSessionDownloadTask] = [:]

    init() {
        let onDisk = Set(
            WhisperModel.all.filter {
                FileManager.default.fileExists(atPath: $0.localURL.path)
            }.map(\.name)
        )
        downloadedNames = onDisk
        let autoName = WhisperModel.all.first(where: { onDisk.contains($0.name) })?.name ?? "base"
        selectedModelName = UserDefaults.standard.string(forKey: "selectedModel") ?? autoName
    }

    var selectedModelURL: URL? {
        if let model = WhisperModel.all.first(where: { $0.name == selectedModelName }),
           downloadedNames.contains(model.name) {
            return model.localURL
        }
        return ModelLocator.defaultModel()
    }

    func dismissDownloadError() {
        lastDownloadError = nil
    }

    func dismissVerification() {
        verification = .idle
    }

    func verifyDownloaded() {
        guard verification != .running else { return }
        verification = .running
        let toCheck: [(displayName: String, url: URL, sha1: String)] = WhisperModel.all
            .filter { downloadedNames.contains($0.name) }
            .map { ($0.displayName, $0.localURL, $0.expectedSHA1) }
        Task.detached { [weak self] in
            var passed: [String] = []
            var failed: [String] = []
            for entry in toCheck {
                do {
                    try WhisperModel.validateFile(at: entry.url, expectedSHA1: entry.sha1)
                    passed.append(entry.displayName)
                } catch {
                    failed.append(entry.displayName)
                }
            }
            await MainActor.run { [weak self] in
                self?.verification = .finished(passed: passed, failed: failed)
                self?.logger.info("Verification finished: \(passed.count) passed, \(failed.count) failed")
            }
        }
    }

    func download(_ model: WhisperModel) {
        guard activeTasks[model.name] == nil else { return }
        activeTasks[model.name] = Task {
            await performDownload(model)
            activeTasks[model.name] = nil
        }
    }

    func cancelDownload(_ model: WhisperModel) {
        activeDownloadTasks[model.name]?.cancel()
        activeDownloadTasks[model.name] = nil
        activeTasks[model.name]?.cancel()
        activeTasks[model.name] = nil
        downloads[model.name] = nil
    }

    func delete(_ model: WhisperModel) {
        try? FileManager.default.removeItem(at: model.localURL)
        downloadedNames.remove(model.name)
        if selectedModelName == model.name {
            let autoName = WhisperModel.all.first { downloadedNames.contains($0.name) }?.name ?? "base"
            selectedModelName = autoName
        }
    }

    private func performDownload(_ model: WhisperModel) async {
        do {
            try ModelLocator.ensureDirectoryExists()
        } catch {
            downloads[model.name] = nil
            lastDownloadError = "\(model.displayName): \(error.localizedDescription)"
            logger.error("Failed to create models directory: \(error.localizedDescription)")
            return
        }

        downloads[model.name] = 0

        let holder = DownloadTaskHolder()

        do {
            let tempURL: URL = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let task = URLSession.shared.downloadTask(with: model.downloadURL) { url, response, error in
                        if let error {
                            continuation.resume(throwing: error)
                            return
                        }

                        if let httpResponse = response as? HTTPURLResponse,
                           !(200...299).contains(httpResponse.statusCode) {
                            continuation.resume(throwing: URLError(
                                .badServerResponse,
                                userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode)"]
                            ))
                            return
                        }

                        guard let url else {
                            continuation.resume(throwing: URLError(.cannotCreateFile))
                            return
                        }

                        let tmp = FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString + ".bin")
                        do {
                            try FileManager.default.moveItem(at: url, to: tmp)
                            continuation.resume(returning: tmp)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }

                    self.activeDownloadTasks[model.name] = task
                    holder.register(task)

                    let observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                        Task { @MainActor [weak self] in
                            self?.downloads[model.name] = progress.fractionCompleted
                        }
                    }
                    objc_setAssociatedObject(task, "obs", observation, .OBJC_ASSOCIATION_RETAIN)

                    task.resume()
                }
            } onCancel: {
                holder.cancel()
            }

            activeDownloadTasks[model.name] = nil

            if Task.isCancelled {
                try? FileManager.default.removeItem(at: tempURL)
                throw CancellationError()
            }

            do {
                try WhisperModel.validateFile(at: tempURL, expectedSHA1: model.expectedSHA1)
            } catch {
                try? FileManager.default.removeItem(at: tempURL)
                throw error
            }

            if FileManager.default.fileExists(atPath: model.localURL.path) {
                try FileManager.default.removeItem(at: model.localURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: model.localURL)

            downloads[model.name] = nil
            downloadedNames.insert(model.name)
            logger.info("Downloaded model: \(model.name)")

            if !WhisperModel.all.contains(where: { $0.name == selectedModelName && downloadedNames.contains($0.name) }) {
                selectedModelName = model.name
            }
        } catch is CancellationError {
            downloads[model.name] = nil
            activeDownloadTasks[model.name] = nil
        } catch let error as URLError where error.code == .cancelled {
            downloads[model.name] = nil
            activeDownloadTasks[model.name] = nil
        } catch {
            downloads[model.name] = nil
            activeDownloadTasks[model.name] = nil
            lastDownloadError = "\(model.displayName): \(error.localizedDescription)"
            logger.error("Download failed for \(model.name): \(error.localizedDescription)")
        }
    }
}

