import Foundation
import OSLog

struct WhisperModel: Identifiable, Equatable {
    let name: String
    let displayName: String
    let sizeLabel: String
    let qualityNote: String
    let fileName: String

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
            sizeLabel: "~75 MB", qualityNote: "Fastest, lower accuracy",
            fileName: "ggml-tiny.bin"
        ),
        WhisperModel(
            name: "base", displayName: "Base",
            sizeLabel: "~142 MB", qualityNote: "Good balance for short dictation",
            fileName: "ggml-base.bin"
        ),
        WhisperModel(
            name: "small", displayName: "Small",
            sizeLabel: "~466 MB", qualityNote: "Better accuracy, still fast on Apple Silicon",
            fileName: "ggml-small.bin"
        ),
        WhisperModel(
            name: "medium", displayName: "Medium",
            sizeLabel: "~1.5 GB", qualityNote: "High accuracy, slower",
            fileName: "ggml-medium.bin"
        ),
        WhisperModel(
            name: "large-v3", displayName: "Large v3",
            sizeLabel: "~3.1 GB", qualityNote: "Best accuracy",
            fileName: "ggml-large-v3.bin"
        ),
        WhisperModel(
            name: "large-v3-turbo", displayName: "Large v3 Turbo",
            sizeLabel: "~809 MB", qualityNote: "Near-best accuracy, much faster",
            fileName: "ggml-large-v3-turbo.bin"
        ),
    ]
}

@Observable
@MainActor
final class ModelManager {
    private(set) var downloads: [String: Double] = [:]
    private(set) var downloadedNames: Set<String>
    private(set) var lastDownloadError: String?
    var selectedModelName: String {
        didSet { UserDefaults.standard.set(selectedModelName, forKey: "selectedModel") }
    }

    private let logger = Logger(subsystem: "com.bartoszadamczyk.Vox", category: "ModelManager")
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
            logger.error("Failed to create models directory: \(error.localizedDescription)")
            return
        }

        downloads[model.name] = 0

        do {
            let tempURL: URL = try await withCheckedThrowingContinuation { continuation in
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

                let observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                    Task { @MainActor [weak self] in
                        self?.downloads[model.name] = progress.fractionCompleted
                    }
                }
                objc_setAssociatedObject(task, "obs", observation, .OBJC_ASSOCIATION_RETAIN)

                task.resume()
            }

            activeDownloadTasks[model.name] = nil

            if Task.isCancelled {
                try? FileManager.default.removeItem(at: tempURL)
                throw CancellationError()
            }

            let attrs = try FileManager.default.attributesOfItem(atPath: tempURL.path)
            let fileSize = attrs[.size] as? Int64 ?? 0
            if fileSize < 1_000_000 {
                try? FileManager.default.removeItem(at: tempURL)
                throw URLError(
                    .dataLengthExceedsMaximum,
                    userInfo: [NSLocalizedDescriptionKey: "Downloaded file too small (\(fileSize) bytes) — likely not a valid model"]
                )
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

