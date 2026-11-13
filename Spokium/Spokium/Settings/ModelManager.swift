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
    // Optional Core ML encoder (runs the encoder on the Neural Engine). Hash is the
    // SHA-256 that Hugging Face publishes for the LFS object.
    let coreMLSizeLabel: String
    let coreMLSHA256: String

    var id: String { name }

    private var stem: String { URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent }

    var coreMLDownloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(stem)-encoder.mlmodelc.zip")!
    }

    var coreMLURL: URL { Self.coreMLURL(forModelAt: localURL) }

    // whisper.cpp looks for `<model>-encoder.mlmodelc` next to `<model>.bin` and uses it
    // automatically (falling back to Metal if it can't be loaded).
    nonisolated static func coreMLURL(forModelAt modelURL: URL) -> URL {
        let stem = modelURL.deletingPathExtension().lastPathComponent
        return modelURL.deletingLastPathComponent().appendingPathComponent("\(stem)-encoder.mlmodelc", isDirectory: true)
    }

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
            expectedSHA1: "bd577a113a864445d4c299885e0cb97d4ba92b5f",
            coreMLSizeLabel: "~15 MB",
            coreMLSHA256: "c88cbd2648e1f5415092bcf5256add463a0f19943e6938f46e8d4ffdebd47739"
        ),
        WhisperModel(
            name: "base", displayName: "Base",
            sizeLabel: "~148 MB", qualityNote: "Good balance for short dictation",
            fileName: "ggml-base.bin",
            expectedSHA1: "465707469ff3a37a2b9b8d8f89f2f99de7299dac",
            coreMLSizeLabel: "~38 MB",
            coreMLSHA256: "7e6ab77041942572f239b5b602f8aaa1c3ed29d73e3d8f20abea03a773541089"
        ),
        WhisperModel(
            name: "small", displayName: "Small",
            sizeLabel: "~488 MB", qualityNote: "Better accuracy, still fast on Apple Silicon",
            fileName: "ggml-small.bin",
            expectedSHA1: "55356645c2b361a969dfd0ef2c5a50d530afd8d5",
            coreMLSizeLabel: "~163 MB",
            coreMLSHA256: "de43fb9fed471e95c19e60ae67575c2bf09e8fb607016da171b06ddad313988b"
        ),
        WhisperModel(
            name: "medium", displayName: "Medium",
            sizeLabel: "~1.5 GB", qualityNote: "High accuracy, slower",
            fileName: "ggml-medium.bin",
            expectedSHA1: "fd9727b6e1217c2f614f9b698455c4ffd82463b4",
            coreMLSizeLabel: "~568 MB",
            coreMLSHA256: "79b0b8d436d47d3f24dd3afc91f19447dd686a4f37521b2f6d9c30a642133fbd"
        ),
        WhisperModel(
            name: "large-v3", displayName: "Large v3",
            sizeLabel: "~3.1 GB", qualityNote: "Best accuracy",
            fileName: "ggml-large-v3.bin",
            expectedSHA1: "ad82bf6a9043ceed055076d0fd39f5f186ff8062",
            coreMLSizeLabel: "~1.2 GB",
            coreMLSHA256: "47837be7594a29429ec08620043390c4d6d467f8bd362df09e9390ace76a55a4"
        ),
        WhisperModel(
            name: "large-v3-turbo", displayName: "Large v3 Turbo",
            sizeLabel: "~1.6 GB", qualityNote: "Near-best accuracy, much faster",
            fileName: "ggml-large-v3-turbo.bin",
            expectedSHA1: "4af2b29d7ec73d781377bfd1758ca957a807e941",
            coreMLSizeLabel: "~1.2 GB",
            coreMLSHA256: "84bedfe895bd7b5de6e8e89a0803dfc5addf8c0c5bc4c937451716bf7cf7988a"
        ),
    ]

    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var context = CC_SHA256_CTX()
        CC_SHA256_Init(&context)
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            chunk.withUnsafeBytes { ptr in
                _ = CC_SHA256_Update(&context, ptr.baseAddress, CC_LONG(ptr.count))
            }
        }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&digest, &context)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

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

extension Notification.Name {
    // Posted with the model's URL as `object` when its Core ML encoder is installed or
    // removed, so a loaded whisper context can be rebuilt to pick the change up.
    static let coreMLEncoderChanged = Notification.Name("SpokiumCoreMLEncoderChanged")
}

enum ModelValidationError: LocalizedError {
    case notGGML
    case checksumMismatch(expected: String, actual: String)
    case coreMLChecksumMismatch
    case coreMLUnpackFailed(String)

    var errorDescription: String? {
        switch self {
        case .notGGML:
            return "File is not a valid GGML model — it may be an error page or corrupted download"
        case .checksumMismatch:
            return "SHA-1 checksum mismatch — the download may be corrupted or incomplete"
        case .coreMLChecksumMismatch:
            return "SHA-256 checksum mismatch for the Core ML encoder — the download may be corrupted"
        case .coreMLUnpackFailed(let reason):
            return "Couldn't unpack the Core ML encoder: \(reason)"
        }
    }
}

@Observable
@MainActor
final class ModelManager {
    private(set) var downloads: [String: Double] = [:]
    private(set) var downloadedNames: Set<String>
    private(set) var coreMLInstalledNames: Set<String>
    private(set) var failedVerificationNames: Set<String> = []
    private(set) var lastDownloadError: String?
    private(set) var verification: VerificationState = .idle

    enum VerificationState: Equatable {
        case idle
        case running
        case finished(passed: [String], failed: [String])
    }
    var selectedModelName: String {
        didSet { AppDefaults.selectedModel = selectedModelName }
    }

    private let logger = Logger(subsystem: "com.spokium.mac", category: "ModelManager")
    private var activeTasks: [String: Task<Void, Never>] = [:]
    private var activeDownloadTasks: [String: URLSessionDownloadTask] = [:]

    init() {
        let onDisk = Set(
            WhisperModel.all.filter {
                FileManager.default.fileExists(atPath: $0.localURL.path)
            }.map(\.name)
        )
        downloadedNames = onDisk
        coreMLInstalledNames = Self.coreMLOnDisk()
        let autoName = WhisperModel.all.first(where: { onDisk.contains($0.name) })?.name ?? "base"
        selectedModelName = AppDefaults.selectedModel ?? autoName
    }

    var selectedModelURL: URL? {
        if let model = WhisperModel.all.first(where: { $0.name == selectedModelName }),
           downloadedNames.contains(model.name) {
            return model.localURL
        }
        return nil
    }

    func refreshDownloadedNames() {
        let onDisk = Set(
            WhisperModel.all.filter {
                FileManager.default.fileExists(atPath: $0.localURL.path)
            }.map(\.name)
        )
        let missing = downloadedNames.subtracting(onDisk)
        for name in missing {
            downloadedNames.remove(name)
        }
        coreMLInstalledNames = Self.coreMLOnDisk()
    }

    private static func coreMLOnDisk() -> Set<String> {
        Set(WhisperModel.all.filter {
            FileManager.default.fileExists(atPath: $0.coreMLURL.path)
        }.map(\.name))
    }

    // MARK: Core ML encoder

    private func coreMLKey(_ model: WhisperModel) -> String { "coreml:\(model.name)" }

    func coreMLProgress(_ model: WhisperModel) -> Double? {
        downloads[coreMLKey(model)]
    }

    func downloadCoreML(_ model: WhisperModel) {
        let key = coreMLKey(model)
        guard activeTasks[key] == nil else { return }
        activeTasks[key] = Task {
            await performCoreMLDownload(model)
            activeTasks[key] = nil
        }
    }

    func cancelCoreMLDownload(_ model: WhisperModel) {
        let key = coreMLKey(model)
        activeDownloadTasks[key]?.cancel()
        activeDownloadTasks[key] = nil
        activeTasks[key]?.cancel()
        activeTasks[key] = nil
        downloads[key] = nil
    }

    func deleteCoreML(_ model: WhisperModel) {
        try? FileManager.default.removeItem(at: model.coreMLURL)
        coreMLInstalledNames.remove(model.name)
        CoreMLHealth.clear(model.localURL)
        NotificationCenter.default.post(name: .coreMLEncoderChanged, object: model.localURL)
    }

    private func performCoreMLDownload(_ model: WhisperModel) async {
        let key = coreMLKey(model)
        downloads[key] = 0
        defer {
            downloads[key] = nil
            activeDownloadTasks[key] = nil
        }
        do {
            try ModelLocator.ensureDirectoryExists()
            let zipURL = try await fetchToTemp(model.coreMLDownloadURL, key: key)
            defer { try? FileManager.default.removeItem(at: zipURL) }
            try Task.checkCancellation()

            let expected = model.coreMLSHA256
            let destination = model.coreMLURL
            // Hashing and unzipping a ~1 GB archive must stay off the main actor.
            try await Task.detached {
                guard try WhisperModel.sha256(of: zipURL) == expected else {
                    throw ModelValidationError.coreMLChecksumMismatch
                }
                try Self.unpackCoreML(zip: zipURL, to: destination)
            }.value

            coreMLInstalledNames.insert(model.name)
            logger.info("Installed Core ML encoder for \(model.name, privacy: .public)")
            NotificationCenter.default.post(name: .coreMLEncoderChanged, object: model.localURL)
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            lastDownloadError = "\(model.displayName) Core ML encoder: \(error.localizedDescription)"
            logger.error("Core ML encoder download failed for \(model.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // Extracts into a staging folder next to the destination (same volume, so the final
    // move is atomic), checks the archive contained the expected .mlmodelc, then swaps
    // it into place. Foundation has no unzip, so this uses the system's ditto.
    nonisolated static func unpackCoreML(zip: URL, to destination: URL) throws {
        let fm = FileManager.default
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".unpack-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, staging.path]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ModelValidationError.coreMLUnpackFailed("ditto exited \(process.terminationStatus) \(message)")
        }

        let unpacked = staging.appendingPathComponent(destination.lastPathComponent, isDirectory: true)
        guard fm.fileExists(atPath: unpacked.path) else {
            throw ModelValidationError.coreMLUnpackFailed("archive didn't contain \(destination.lastPathComponent)")
        }
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: unpacked, to: destination)
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
        let toCheck: [(name: String, displayName: String, url: URL, sha1: String)] = WhisperModel.all
            .filter { FileManager.default.fileExists(atPath: $0.localURL.path) }
            .map { ($0.name, $0.displayName, $0.localURL, $0.expectedSHA1) }
        Task.detached { [weak self] in
            var passed: [String] = []
            var passedNames: [String] = []
            var failed: [String] = []
            var failedNames: [String] = []
            var failedURLs: [URL] = []
            for entry in toCheck {
                do {
                    try WhisperModel.validateFile(at: entry.url, expectedSHA1: entry.sha1)
                    passed.append(entry.displayName)
                    passedNames.append(entry.name)
                } catch {
                    failed.append(entry.displayName)
                    failedNames.append(entry.name)
                    failedURLs.append(entry.url)
                }
            }
            for url in failedURLs {
                try? FileManager.default.removeItem(at: url)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                for name in passedNames {
                    self.downloadedNames.insert(name)
                    self.failedVerificationNames.remove(name)
                }
                for name in failedNames {
                    self.downloadedNames.remove(name)
                    self.failedVerificationNames.insert(name)
                }
                self.verification = .finished(passed: passed, failed: failed)
                self.logger.info("Verification finished: \(passed.count) passed, \(failed.count) failed")
            }
        }
    }

    func download(_ model: WhisperModel) {
        guard activeTasks[model.name] == nil else { return }
        failedVerificationNames.remove(model.name)
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
        if coreMLInstalledNames.contains(model.name) {
            deleteCoreML(model)
        }
        downloadedNames.remove(model.name)
        failedVerificationNames.remove(model.name)
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

        do {
            let tempURL = try await fetchToTemp(model.downloadURL, key: model.name)
            activeDownloadTasks[model.name] = nil

            if Task.isCancelled {
                try? FileManager.default.removeItem(at: tempURL)
                throw CancellationError()
            }

            do {
                // Hashing 1.6–3 GB on the main actor froze the UI and the hotkey.
                let expected = model.expectedSHA1
                try await Task.detached(priority: .userInitiated) {
                    try WhisperModel.validateFile(at: tempURL, expectedSHA1: expected)
                }.value
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

    // Downloads `url` to a temp file, reporting progress under `downloads[key]` and
    // keeping the URLSessionDownloadTask so cancelDownload/cancelCoreMLDownload work.
    private func fetchToTemp(_ url: URL, key: String) async throws -> URL {
        let holder = DownloadTaskHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = URLSession.shared.downloadTask(with: url) { url, response, error in
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
                        .appendingPathComponent(UUID().uuidString + ".download")
                    do {
                        try FileManager.default.moveItem(at: url, to: tmp)
                        continuation.resume(returning: tmp)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }

                self.activeDownloadTasks[key] = task
                holder.register(task)

                let observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                    Task { @MainActor [weak self] in
                        self?.downloads[key] = progress.fractionCompleted
                    }
                }
                objc_setAssociatedObject(task, "obs", observation, .OBJC_ASSOCIATION_RETAIN)

                task.resume()
            }
        } onCancel: {
            holder.cancel()
        }
    }
}
