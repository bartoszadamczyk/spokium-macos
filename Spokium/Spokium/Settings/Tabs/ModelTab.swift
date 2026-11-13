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

    // Recursive so Core ML encoders (.mlmodelc directories) are counted too.
    private func computeUsed() -> Int64 {
        let dir = ModelLocator.modelsDirectory
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
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
    @State private var coreMLPerfRecord: ModelPerformanceStore.Record?

    private var modelStem: String {
        URL(fileURLWithPath: model.fileName).deletingPathExtension().lastPathComponent
    }

    private func reloadPerformance() {
        perfRecord = ModelPerformanceStore.read(modelStem: ModelPerformanceStore.key(modelStem: modelStem, coreML: false))
        coreMLPerfRecord = ModelPerformanceStore.read(modelStem: ModelPerformanceStore.key(modelStem: modelStem, coreML: true))
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
                // Prefixes only once Neural Engine stats exist; until then there's one line.
                if let perf = perfRecord {
                    Text(coreMLPerfRecord == nil ? perf.summary : "GPU: \(perf.summary)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if let perf = coreMLPerfRecord {
                    Text("Neural Engine: \(perf.summary)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if manager.downloadedNames.contains(model.name) {
                    CoreMLEncoderRow(model: model, manager: manager)
                        .padding(.top, 2)
                }
            }
            .onAppear(perform: reloadPerformance)
            .onChange(of: controller.state) { _, newState in
                if newState == .idle { reloadPerformance() }
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

// Optional Neural Engine encoder for a downloaded model. Helps most on Macs whose GPU is
// modest relative to the Neural Engine (e.g. M1/M2 Pro and base chips).
struct CoreMLEncoderRow: View {
    let model: WhisperModel
    @Bindable var manager: ModelManager
    @Environment(RecordingController.self) private var controller
    @State private var unusable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            encoderRow
            if unusable, manager.coreMLInstalledNames.contains(model.name) {
                HStack(spacing: 6) {
                    Text("Didn't finish preparing on this Mac — using the GPU instead.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Retry") {
                        CoreMLHealth.clear(model.localURL)
                        NotificationCenter.default.post(name: .coreMLEncoderChanged, object: model.localURL)
                    }
                    .controlSize(.small)
                    .help("Try the Neural Engine again. Dictation keeps using the GPU until it's ready.")
                }
            }
        }
        .task {
            unusable = CoreMLHealth.isUnusable(model.localURL)
            for await _ in NotificationCenter.default.notifications(named: .coreMLHealthChanged) {
                unusable = CoreMLHealth.isUnusable(model.localURL)
            }
        }
    }

    private var encoderRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "cpu")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Neural Engine encoder")
                .font(.caption)
            Text(model.coreMLSizeLabel)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let progress = manager.coreMLProgress(model) {
                ProgressView(value: progress)
                    .controlSize(.small)
                    .frame(width: 70)
                Button {
                    manager.cancelCoreMLDownload(model)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else if manager.coreMLInstalledNames.contains(model.name) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Button {
                    manager.deleteCoreML(model)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(manager.selectedModelName == model.name && controller.state != .idle)
            } else {
                Button("Download") {
                    manager.downloadCoreML(model)
                }
                .controlSize(.small)
            }
        }
        .help("Runs whisper's encoder on the Apple Neural Engine via Core ML. Usually faster on M1/M2-class GPUs and lighter on battery. The first use after installing compiles it for your Mac, which can take a few minutes once; dictation runs on the GPU until it's ready. If it isn't ready within 10 minutes, Spokium stops using it on this Mac.")
    }
}

