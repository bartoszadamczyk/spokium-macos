import Foundation
import Testing
@testable import Spokium

@MainActor
struct WhisperModelTests {
    @Test func all_returnsAtLeastTinyAndBase() {
        let names = Set(WhisperModel.all.map(\.name))
        #expect(names.contains("tiny"))
        #expect(names.contains("base"))
    }

    @Test func all_namesAreUnique() {
        let names = WhisperModel.all.map(\.name)
        #expect(Set(names).count == names.count)
    }

    @Test func all_fileNamesAreUnique() {
        let fileNames = WhisperModel.all.map(\.fileName)
        #expect(Set(fileNames).count == fileNames.count)
    }

    @Test func all_haveNonEmptyMetadata() {
        for model in WhisperModel.all {
            #expect(!model.name.isEmpty)
            #expect(!model.displayName.isEmpty)
            #expect(!model.sizeLabel.isEmpty)
            #expect(!model.qualityNote.isEmpty)
            #expect(!model.fileName.isEmpty)
            #expect(!model.expectedSHA1.isEmpty)
        }
    }

    @Test func all_sha1sAreExactly40LowercaseHexChars() {
        let hexSet = Set("0123456789abcdef")
        for model in WhisperModel.all {
            #expect(
                model.expectedSHA1.count == 40,
                "SHA-1 for \(model.name) should be 40 chars, got \(model.expectedSHA1.count)"
            )
            #expect(
                model.expectedSHA1.allSatisfy { hexSet.contains($0) },
                "SHA-1 for \(model.name) contains non-hex / uppercase chars: \(model.expectedSHA1)"
            )
        }
    }

    @Test func all_fileNamesHaveGgmlPrefixAndBinSuffix() {
        for model in WhisperModel.all {
            #expect(
                model.fileName.hasPrefix("ggml-"),
                "Expected ggml- prefix on \(model.fileName)"
            )
            #expect(
                model.fileName.hasSuffix(".bin"),
                "Expected .bin suffix on \(model.fileName)"
            )
        }
    }

    @Test func downloadURL_pointsAtHuggingFaceWhisperCppRepo() {
        for model in WhisperModel.all {
            let urlString = model.downloadURL.absoluteString
            #expect(
                urlString.hasPrefix("https://huggingface.co/ggerganov/whisper.cpp/"),
                "Unexpected download host for \(model.name): \(urlString)"
            )
            #expect(
                urlString.hasSuffix(model.fileName),
                "Download URL should end with file name for \(model.name)"
            )
        }
    }
}
