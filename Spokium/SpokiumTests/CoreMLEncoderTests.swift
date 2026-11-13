import Foundation
import Testing

@testable import Spokium

@MainActor
struct CoreMLEncoderTests {
    @Test
    func everyModel_hasWellFormedSHA256() {
        for model in WhisperModel.all {
            #expect(model.coreMLSHA256.count == 64, "\(model.name)")
            #expect(model.coreMLSHA256.allSatisfy { $0.isHexDigit && !$0.isUppercase }, "\(model.name)")
        }
    }

    @Test
    func coreMLPaths_followWhisperCppNaming() {
        let model = WhisperModel.all.first { $0.name == "large-v3" }!
        #expect(model.coreMLURL.lastPathComponent == "ggml-large-v3-encoder.mlmodelc")
        #expect(model.coreMLURL.deletingLastPathComponent() == model.localURL.deletingLastPathComponent())
        #expect(model.coreMLDownloadURL.absoluteString
            == "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-encoder.mlmodelc.zip")
    }

    @Test
    func sha256_matchesKnownDigest() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sha-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try WhisperModel.sha256(of: url)
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    // Runs inside the sandboxed test host, so it also proves /usr/bin/ditto can be
    // launched from the sandbox.
    @Test
    func unpack_extractsMlmodelcFromZip() throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("coreml-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let source = work.appendingPathComponent("src/ggml-test-encoder.mlmodelc", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: source.appendingPathComponent("weights.bin"))

        let zip = work.appendingPathComponent("encoder.zip")
        let zipper = Process()
        zipper.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zipper.arguments = ["-c", "-k", "--keepParent", source.path, zip.path]
        try zipper.run()
        zipper.waitUntilExit()
        #expect(zipper.terminationStatus == 0)

        let destination = work.appendingPathComponent("models/ggml-test-encoder.mlmodelc", isDirectory: true)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ModelManager.unpackCoreML(zip: zip, to: destination)

        #expect(fm.fileExists(atPath: destination.appendingPathComponent("weights.bin").path))
        let leftovers = try fm.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)
        #expect(leftovers == ["ggml-test-encoder.mlmodelc"], "staging folder should be cleaned up")
    }

    @Test
    func unpack_rejectsArchiveWithoutExpectedBundle() throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("coreml-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let wrong = work.appendingPathComponent("src/something-else", isDirectory: true)
        try fm.createDirectory(at: wrong, withIntermediateDirectories: true)
        let zip = work.appendingPathComponent("bad.zip")
        let zipper = Process()
        zipper.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zipper.arguments = ["-c", "-k", "--keepParent", wrong.path, zip.path]
        try zipper.run()
        zipper.waitUntilExit()

        let destination = work.appendingPathComponent("models/ggml-test-encoder.mlmodelc", isDirectory: true)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(throws: ModelValidationError.self) {
            try ModelManager.unpackCoreML(zip: zip, to: destination)
        }
        #expect(!fm.fileExists(atPath: destination.path))
    }
}
