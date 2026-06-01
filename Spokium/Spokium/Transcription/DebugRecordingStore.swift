import AppKit
import Foundation
import OSLog

// Manages the on-disk debug-recordings folder used when AppDefaults.debugMode is
// true. Audio segments that would normally be deleted after transcription are
// instead moved here so the developer can inspect them. Size-capped so the
// folder can't grow without bound.
//
// Path: ~/Library/Containers/com.spokium.mac/Data/Library/Application Support/Spokium/debug-recordings/
//
// Privacy posture: only populated when debugMode is on. cleanIfDisabled()
// removes the folder entirely whenever debugMode flips off (called on launch
// and from the UserDefaults observer in AppDelegate).
nonisolated enum DebugRecordingStore {
    private static let logger = Logger(subsystem: "com.spokium.mac", category: "DebugRecordings")
    private static let sizeCap: Int64 = 100 * 1_048_576 // 100 MB

    nonisolated static var directory: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Spokium/debug-recordings", isDirectory: true)
    }

    nonisolated static func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    // Moves the given audio URLs into the debug folder, then enforces the size cap.
    // When `debugSegments` is non-nil, also writes a markdown sidecar next to the
    // first moved audio file containing the per-segment whisper output. Source
    // files are gone afterward — the caller does NOT need to delete them.
    nonisolated static func persistAndConsume(_ urls: [URL], debugSegments: [DebugSegment]? = nil) {
        do {
            try ensureDirectoryExists()
        } catch {
            logger.warning("Failed to create debug folder: \(error.localizedDescription, privacy: .public)")
            return
        }
        var movedDestinations: [URL] = []
        for url in urls {
            let dest = directory.appendingPathComponent(url.lastPathComponent)
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.moveItem(at: url, to: dest)
                movedDestinations.append(dest)
            } catch {
                logger.warning("Failed to move \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                try? FileManager.default.removeItem(at: url)
            }
        }
        if let debugSegments, let first = movedDestinations.first {
            writeSidecar(for: first, audioFiles: movedDestinations, segments: debugSegments)
        }
        enforceSizeCap()
    }

    nonisolated static func renderSidecar(audioFileNames: [String], segments: [DebugSegment], now: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var out = "# Whisper Debug Log\n\n"
        out += "- **Time**: \(formatter.string(from: now))\n"
        if audioFileNames.count == 1 {
            out += "- **Audio**: \(audioFileNames[0])\n"
        } else {
            out += "- **Audio segments**: \(audioFileNames.joined(separator: ", "))\n"
        }
        out += "\n## Segments\n\n"
        if segments.isEmpty {
            out += "_(no segments returned)_\n"
            return out
        }
        out += "| # | start | end | no_speech_prob | text |\n"
        out += "|---|-------|-----|----------------|------|\n"
        for s in segments {
            let safeText = s.text
                .replacingOccurrences(of: "|", with: "\\|")
                .replacingOccurrences(of: "\n", with: " ")
            out += String(
                format: "| %d | %.2fs | %.2fs | %.3f | %@ |\n",
                s.index, s.startSeconds, s.endSeconds, s.noSpeechProb, safeText as NSString
            )
        }
        return out
    }

    private nonisolated static func writeSidecar(for audioURL: URL, audioFiles: [URL], segments: [DebugSegment]) {
        let sidecarURL = audioURL.deletingPathExtension().appendingPathExtension("md")
        let body = renderSidecar(
            audioFileNames: audioFiles.map(\.lastPathComponent),
            segments: segments
        )
        do {
            try body.write(to: sidecarURL, atomically: true, encoding: .utf8)
        } catch {
            logger.warning("Failed to write sidecar \(sidecarURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // Removes the entire debug folder. Safe to call repeatedly.
    nonisolated static func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    // Idempotent: deletes the folder if debugMode is currently off.
    nonisolated static func cleanIfDisabled() {
        guard !AppDefaults.debugMode else { return }
        clear()
    }

    nonisolated static func revealInFinder() {
        try? ensureDirectoryExists()
        NSWorkspace.shared.open(directory)
    }

    // Enforces the directory size cap by dropping oldest files until under cap.
    nonisolated static func enforceSizeCap() {
        let files = listFiles()
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        guard total > sizeCap else { return }
        var sorted = files.sorted { $0.modified < $1.modified }
        var running = total
        while running > sizeCap, let oldest = sorted.first {
            try? FileManager.default.removeItem(at: oldest.url)
            running -= oldest.size
            sorted.removeFirst()
        }
    }

    private struct FileInfo {
        let url: URL
        let size: Int64
        let modified: Date
    }

    private nonisolated static func listFiles() -> [FileInfo] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return [] }
        return urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard let size = values?.fileSize, let modified = values?.contentModificationDate else { return nil }
            return FileInfo(url: url, size: Int64(size), modified: modified)
        }
    }
}
