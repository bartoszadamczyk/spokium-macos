import CommonCrypto
import Foundation
import Testing
@testable import Spokium

@MainActor
struct ModelValidationTests {
    // Bytes that the production validator accepts as "ggml" magic. The validator
    // does `Data(...).load(as: UInt32.self)` (native little-endian) and compares
    // against 0x67676D6C, so the on-disk byte sequence must be [0x6C, 0x6D, 0x67, 0x67].
    private static let validGGMLMagic: [UInt8] = [0x6C, 0x6D, 0x67, 0x67]

    private func writeTempFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("modelvalidation-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        return url
    }

    private func sha1(_ bytes: [UInt8]) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        bytes.withUnsafeBytes { ptr in
            _ = CC_SHA1(ptr.baseAddress, CC_LONG(bytes.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    @Test func validMagicAndChecksum_passesValidation() throws {
        let payload: [UInt8] = Self.validGGMLMagic + Array(repeating: UInt8(0xAA), count: 200)
        let url = try writeTempFile(payload)
        defer { try? FileManager.default.removeItem(at: url) }

        // Should not throw.
        try WhisperModel.validateFile(at: url, expectedSHA1: sha1(payload))
    }

    @Test func badMagic_throwsNotGGML() throws {
        let payload: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF] + Array(repeating: UInt8(0), count: 64)
        let url = try writeTempFile(payload)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: ModelValidationError.self) {
            try WhisperModel.validateFile(at: url, expectedSHA1: "0000000000000000000000000000000000000000")
        }
    }

    @Test func validMagicWrongChecksum_throwsChecksumMismatch() throws {
        let payload: [UInt8] = Self.validGGMLMagic + Array(repeating: UInt8(0xAA), count: 200)
        let url = try writeTempFile(payload)
        defer { try? FileManager.default.removeItem(at: url) }

        var threw = false
        do {
            try WhisperModel.validateFile(
                at: url,
                expectedSHA1: "ffffffffffffffffffffffffffffffffffffffff"
            )
        } catch ModelValidationError.checksumMismatch {
            threw = true
        } catch {
            // wrong error
        }
        #expect(threw)
    }

    @Test func fileTooShortToReadMagic_throwsNotGGML() throws {
        let payload: [UInt8] = [0x6C, 0x6D, 0x67] // only 3 bytes — short of the 4-byte magic
        let url = try writeTempFile(payload)
        defer { try? FileManager.default.removeItem(at: url) }

        var threw = false
        do {
            try WhisperModel.validateFile(at: url, expectedSHA1: sha1(payload))
        } catch ModelValidationError.notGGML {
            threw = true
        } catch {
            // wrong error
        }
        #expect(threw)
    }
}
