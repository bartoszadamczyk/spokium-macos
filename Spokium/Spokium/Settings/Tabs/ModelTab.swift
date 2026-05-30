import AppKit
import SwiftUI

struct ModelTab: View {
    @State private var modelManager = ModelManager()

    private var showError: Binding<Bool> {
        Binding(
            get: { modelManager.lastDownloadError != nil },
            set: { if !$0 { modelManager.dismissDownloadError() } }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(WhisperModel.all) { model in
                    ModelRow(model: model, manager: modelManager)
                }
            }
            .listStyle(.inset)

            HStack(spacing: 16) {
                Button("Show in Finder") {
                    try? ModelLocator.ensureDirectoryExists()
                    NSWorkspace.shared.open(ModelLocator.modelsDirectory)
                }
                .buttonStyle(.link)
                .font(.callout)

                Button(verifyButtonLabel) {
                    modelManager.verifyDownloaded()
                }
                .buttonStyle(.link)
                .font(.callout)
                .disabled(modelManager.verification == .running)

                if case .finished(let passed, let failed) = modelManager.verification {
                    Text(verificationSummary(passed: passed, failed: failed))
                        .font(.callout)
                        .foregroundStyle(failed.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.red))
                }

                Spacer()

                DiskUsageView(downloadedNames: modelManager.downloadedNames)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .task { modelManager.refreshDownloadedNames() }
        .alert("Download Failed", isPresented: showError) {
            Button("OK") { modelManager.dismissDownloadError() }
        } message: {
            Text(modelManager.lastDownloadError ?? "")
        }
    }

    private var verifyButtonLabel: String {
        modelManager.verification == .running ? "Verifying…" : "Verify Hashes"
    }

    private func verificationSummary(passed: [String], failed: [String]) -> String {
        if passed.isEmpty && failed.isEmpty {
            return "No models found in directory"
        }
        if failed.isEmpty {
            return "All \(passed.count) verified"
        }
        return "Failed: \(failed.joined(separator: ", "))"
    }
}

struct DiskUsageView: View {
    let downloadedNames: Set<String>
    @State private var usedBytes: Int64 = 0
    @State private var freeBytes: Int64 = 0

    var body: some View {
        Text(label)
            .font(.callout)
            .foregroundStyle(.secondary)
            .onAppear(perform: recompute)
            .onChange(of: downloadedNames) { _, _ in recompute() }
    }

    private var label: String {
        let used = ByteCountFormatter.string(fromByteCount: usedBytes, countStyle: .file)
        let free = ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
        return "\(used) used · \(free) free"
    }

    private func recompute() {
        usedBytes = computeUsed()
        freeBytes = computeFree()
    }

    private func computeUsed() -> Int64 {
        let dir = ModelLocator.modelsDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return files.reduce(Int64(0)) { sum, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return sum + Int64(size)
        }
    }

    private func computeFree() -> Int64 {
        try? ModelLocator.ensureDirectoryExists()
        let dir = ModelLocator.modelsDirectory
        let values = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }
}

struct ModelRow: View {
    let model: WhisperModel
    @Bindable var manager: ModelManager
    @Environment(RecordingController.self) private var controller
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var perfRecord: ModelPerformanceStore.Record?

    private var modelStem: String {
        URL(fileURLWithPath: model.fileName).deletingPathExtension().lastPathComponent
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.displayName)
                        .fontWeight(.medium)
                    Text(model.sizeLabel)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                Text(model.qualityNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let perf = perfRecord {
                    Text(perf.summary)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .onAppear { perfRecord = ModelPerformanceStore.read(modelStem: modelStem) }
            .onChange(of: controller.state) { _, newState in
                if newState == .idle {
                    perfRecord = ModelPerformanceStore.read(modelStem: modelStem)
                }
            }

            Spacer()

            if let progress = manager.downloads[model.name] {
                HStack(spacing: 8) {
                    ProgressView(value: progress)
                        .frame(width: 80)
                    Button {
                        manager.cancelDownload(model)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            } else if manager.downloadedNames.contains(model.name) {
                HStack(spacing: 8) {
                    if manager.selectedModelName == model.name {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(controlActiveState == .inactive ? .secondary : .accentColor)
                    } else {
                        Button("Select") {
                            manager.selectedModelName = model.name
                        }
                    }
                    Button {
                        manager.delete(model)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(manager.selectedModelName == model.name && controller.state != .idle)
                }
            } else if manager.failedVerificationNames.contains(model.name) {
                Button("Redownload") {
                    manager.download(model)
                }
                .foregroundStyle(.red)
            } else {
                Button("Download") {
                    manager.download(model)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
