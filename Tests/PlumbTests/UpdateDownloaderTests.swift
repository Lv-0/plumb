import Testing
import Foundation
import CryptoKit
@testable import Plumb

@Suite("UpdateDownloader")
struct UpdateDownloaderTests {

    @Test("verifySHA256 passes for matching digest")
    func verifyPasses() {
        let bytes = Data("hello plumb".utf8)
        let digest = SHA256.hash(data: bytes).compactMap { String(format: "%02x", $0) }.joined()
        #expect(UpdateDownloader.verifySHA256(data: bytes, expectedHex: digest) == true)
    }

    @Test("verifySHA256 fails for mismatched digest")
    func verifyFails() {
        let bytes = Data("hello plumb".utf8)
        let wrong = String(repeating: "0", count: 64)
        #expect(UpdateDownloader.verifySHA256(data: bytes, expectedHex: wrong) == false)
    }

    @Test("verifySHA256 fails for malformed hex")
    func verifyMalformedHex() {
        let bytes = Data("x".utf8)
        #expect(UpdateDownloader.verifySHA256(data: bytes, expectedHex: "nothex") == false)
    }

    @Test("verifySHA256 is case-insensitive")
    func verifyCaseInsensitive() {
        let bytes = Data("Plumb OTA".utf8)
        let digestUpper = SHA256.hash(data: bytes).compactMap { String(format: "%02X", $0) }.joined()
        #expect(UpdateDownloader.verifySHA256(data: bytes, expectedHex: digestUpper) == true)
    }
}
