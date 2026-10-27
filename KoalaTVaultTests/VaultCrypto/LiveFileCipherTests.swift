import CryptoKit
import Foundation
import Testing

@testable import KoalaTVault

// Assumes the initializer `LiveFileCipher(keyStore: MasterKeyStoring)`.
@Suite struct LiveFileCipherTests {
    private let mebibyte = SVC5Builder.mebibyte

    private func makeCipher(keyLoaded: Bool = true) -> LiveFileCipher {
        LiveFileCipher(keyStore: MockMasterKeyStoring(keyLoaded: keyLoaded))
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = try SVC5Builder.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func listing(_ directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    // MARK: encrypt / decrypt (data)

    @Test("Data round-trips with the same context")
    func dataRoundTrip() throws {
        let cipher = makeCipher()
        let plain = SVC5Builder.pattern(500)
        let sealed = try cipher.encrypt(plain, context: ".vault_map")
        #expect(try cipher.decrypt(sealed, contexts: [".vault_map"]) == plain)
    }

    @Test("Empty data round-trips")
    func emptyDataRoundTrip() throws {
        let cipher = makeCipher()
        let sealed = try cipher.encrypt(Data(), context: "ctx")
        #expect(sealed.count == 28)
        #expect(try cipher.decrypt(sealed, contexts: ["ctx"]).isEmpty)
    }

    @Test("Encrypted data is nonce 12, ciphertext, tag 16 with the context as AAD")
    func dataFormat() throws {
        let cipher = makeCipher()
        let plain = SVC5Builder.pattern(40)
        let sealed = try cipher.encrypt(plain, context: ".trash_map")
        #expect(sealed.count == 12 + 40 + 16)
        let box = try AES.GCM.SealedBox(combined: sealed)
        let opened = try AES.GCM.open(box, using: SVC5Builder.masterKey, authenticating: Data(".trash_map".utf8))
        #expect(opened == plain)
    }

    @Test("Data sealed independently with the master key and context decrypts")
    func decryptsIndependentlySealedData() throws {
        let plain = SVC5Builder.pattern(64)
        let sealed = try AES.GCM.seal(plain, using: SVC5Builder.masterKey, authenticating: Data("a/b".utf8))
        let combined = try #require(sealed.combined)
        #expect(try makeCipher().decrypt(combined, contexts: ["a/b"]) == plain)
    }

    @Test("Any listed context that matches decrypts, wherever it is in the list")
    func multipleContextsAreTriedInOrder() throws {
        let cipher = makeCipher()
        let plain = SVC5Builder.pattern(30)
        let sealed = try cipher.encrypt(plain, context: "third")
        #expect(try cipher.decrypt(sealed, contexts: ["first", "second", "third"]) == plain)
        #expect(try cipher.decrypt(sealed, contexts: ["third", "first"]) == plain)
        #expect(try cipher.decrypt(sealed, contexts: ["", "third"]) == plain)
    }

    @Test("A context that is not listed fails with decryptionFailed")
    func wrongContextFails() throws {
        let cipher = makeCipher()
        let sealed = try cipher.encrypt(SVC5Builder.pattern(30), context: "right")
        #expect(throws: VaultCryptoError.decryptionFailed) { try cipher.decrypt(sealed, contexts: ["wrong", "other"]) }
    }

    @Test("An empty context list fails with decryptionFailed")
    func emptyContextListFails() throws {
        let cipher = makeCipher()
        let sealed = try cipher.encrypt(SVC5Builder.pattern(30), context: "right")
        #expect(throws: VaultCryptoError.decryptionFailed) { try cipher.decrypt(sealed, contexts: []) }
    }

    @Test("Data sealed with another key fails with decryptionFailed")
    func otherKeyFails() throws {
        let other = SymmetricKey(data: Data(repeating: 0x99, count: 32))
        let sealed = try AES.GCM.seal(SVC5Builder.pattern(30), using: other, authenticating: Data("ctx".utf8))
        let combined = try #require(sealed.combined)
        #expect(throws: VaultCryptoError.decryptionFailed) { try makeCipher().decrypt(combined, contexts: ["ctx"]) }
    }

    @Test("Tampered or too-short data fails with decryptionFailed")
    func tamperedDataFails() throws {
        let cipher = makeCipher()
        var sealed = try cipher.encrypt(SVC5Builder.pattern(30), context: "ctx")
        let last = sealed.count - 1
        sealed[last] ^= 0x01
        #expect(throws: VaultCryptoError.decryptionFailed) { try cipher.decrypt(sealed, contexts: ["ctx"]) }
        #expect(throws: VaultCryptoError.decryptionFailed) { try cipher.decrypt(Data(repeating: 1, count: 10), contexts: ["ctx"]) }
        #expect(throws: VaultCryptoError.decryptionFailed) { try cipher.decrypt(Data(), contexts: ["ctx"]) }
    }

    @Test("Encrypting data uses a different nonce on every call")
    func dataNonceDiffersPerCall() throws {
        let cipher = makeCipher()
        let plain = SVC5Builder.pattern(30)
        let first = try cipher.encrypt(plain, context: "ctx")
        let second = try cipher.encrypt(plain, context: "ctx")
        #expect(first != second)
        #expect(first.prefix(12) != second.prefix(12))
    }

    @Test("Data encrypt and decrypt without a key throw noKeyLoaded")
    func dataWithoutKey() throws {
        let cipher = makeCipher(keyLoaded: false)
        #expect(throws: VaultCryptoError.noKeyLoaded) { try cipher.encrypt(Data([1]), context: "ctx") }
        #expect(throws: VaultCryptoError.noKeyLoaded) { try cipher.decrypt(Data(count: 40), contexts: ["ctx"]) }
    }

    // MARK: encryptFile / decryptFile

    @Test("Files round-trip at the chunk boundaries", arguments: [0, 1, 1000, 1_048_575, 1_048_576, 1_048_577, 2_621_440])
    func fileRoundTrip(size: Int) throws {
        try withDirectory { directory in
            let cipher = makeCipher()
            let plain = SVC5Builder.pattern(size)
            let source = directory.appendingPathComponent("plain")
            let sealed = directory.appendingPathComponent("sealed")
            let output = directory.appendingPathComponent("output")
            try plain.write(to: source)
            try cipher.encryptFile(at: source, to: sealed)
            try cipher.decryptFile(at: sealed, to: output)
            #expect(try Data(contentsOf: output) == plain)
            #expect(try Data(contentsOf: source) == plain)
        }
    }

    @Test("Encrypting a file onto itself works and leaves an SVC5 file that decrypts onto itself")
    func sourceEqualsDestination() throws {
        try withDirectory { directory in
            let cipher = makeCipher()
            let plain = SVC5Builder.pattern(5000)
            let url = directory.appendingPathComponent("file")
            try plain.write(to: url)
            try cipher.encryptFile(at: url, to: url)
            let sealed = try Data(contentsOf: url)
            #expect(SVC5Builder.slice(sealed, 0, 4) == Data("SVC5".utf8))
            try cipher.decryptFile(at: url, to: url)
            #expect(try Data(contentsOf: url) == plain)
            #expect(try listing(directory) == ["file"])
        }
    }

    @Test("Encrypting replaces an existing destination and leaves no staging file")
    func encryptReplacesDestination() throws {
        try withDirectory { directory in
            let cipher = makeCipher()
            let source = directory.appendingPathComponent("plain")
            let destination = directory.appendingPathComponent("sealed")
            try SVC5Builder.pattern(300).write(to: source)
            try Data("old".utf8).write(to: destination)
            try cipher.encryptFile(at: source, to: destination)
            #expect(SVC5Builder.slice(try Data(contentsOf: destination), 0, 4) == Data("SVC5".utf8))
            #expect(try listing(directory) == ["plain", "sealed"])
        }
    }

    @Test("Encrypting a file without a key throws noKeyLoaded and writes no output")
    func encryptFileWithoutKey() throws {
        try withDirectory { directory in
            let cipher = makeCipher(keyLoaded: false)
            let source = directory.appendingPathComponent("plain")
            let destination = directory.appendingPathComponent("sealed")
            try SVC5Builder.pattern(300).write(to: source)
            #expect(throws: VaultCryptoError.noKeyLoaded) { try cipher.encryptFile(at: source, to: destination) }
            #expect(try listing(directory) == ["plain"])
        }
    }

    @Test("A failed encrypt leaves an existing destination untouched")
    func encryptFileWithoutKeyKeepsDestination() throws {
        try withDirectory { directory in
            let cipher = makeCipher(keyLoaded: false)
            let source = directory.appendingPathComponent("plain")
            let destination = directory.appendingPathComponent("sealed")
            try SVC5Builder.pattern(300).write(to: source)
            try Data("keep".utf8).write(to: destination)
            #expect(throws: VaultCryptoError.noKeyLoaded) { try cipher.encryptFile(at: source, to: destination) }
            #expect(try Data(contentsOf: destination) == Data("keep".utf8))
            #expect(try listing(directory) == ["plain", "sealed"])
        }
    }

    @Test("Decrypting a file replaces an existing destination")
    func decryptReplacesDestination() throws {
        try withDirectory { directory in
            let plain = SVC5Builder.pattern(2500)
            let source = directory.appendingPathComponent("sealed")
            let destination = directory.appendingPathComponent("output")
            try SVC5Builder.make(plaintext: plain, chunkSize: 1000).write(to: source)
            try Data("old".utf8).write(to: destination)
            try makeCipher().decryptFile(at: source, to: destination)
            #expect(try Data(contentsOf: destination) == plain)
            #expect(try listing(directory) == ["output", "sealed"])
        }
    }

    /// Named corruptions of a valid three-chunk file (chunk size 1000, 2500 bytes).
    private enum Corruption: String, CaseIterable, CustomTestStringConvertible {
        case wrongMagic, flippedChunkSizeLow, flippedChunkSizeMid, flippedChunkSizeHigh, flippedSizeByte, flippedSizeHighByte
        case flippedFileIDFirst, flippedFileIDLast, swappedChunks, foreignChunk, droppedLastChunk, droppedAllChunks
        case truncatedMidChunk, truncatedMidPrefix, truncatedMidHeader, trailingByte, trailingChunkLikeBytes
        case sizeLargerThanBody, sizeSmallerThanBody, flippedCiphertextByte, flippedTagByte, otherKey

        var testDescription: String { rawValue }

        func apply(to file: Data) throws -> Data {
            var data = file
            let records = SVC5Builder.records(of: file)
            let header = SVC5Builder.slice(file, 0, 32)
            let foreign = try SVC5Builder.make(
                plaintext: SVC5Builder.pattern(2500, seed: 99), chunkSize: 1000, fileID: Data(repeating: 0x77, count: 16))
            switch self {
            case .wrongMagic: data[0] = UInt8(ascii: "X")
            case .flippedChunkSizeLow: data[4] ^= 0x01
            case .flippedChunkSizeMid: data[6] ^= 0x01
            case .flippedChunkSizeHigh: data[7] ^= 0x01
            case .flippedSizeByte: data[8] ^= 0x01
            case .flippedSizeHighByte: data[15] ^= 0x01
            case .flippedFileIDFirst: data[16] ^= 0x01
            case .flippedFileIDLast: data[31] ^= 0x01
            case .swappedChunks: data = header + records[1] + records[0] + records[2]
            case .foreignChunk: data = header + records[0] + SVC5Builder.records(of: foreign)[1] + records[2]
            case .droppedLastChunk: data = header + records[0] + records[1]
            case .droppedAllChunks: data = header
            case .truncatedMidChunk: data = Data(file.dropLast(10))
            case .truncatedMidPrefix: data = header + records[0] + records[1] + records[2].prefix(2)
            case .truncatedMidHeader: data = Data(file.prefix(20))
            case .trailingByte: data.append(0x00)
            case .trailingChunkLikeBytes: data.append(records[0])
            case .sizeLargerThanBody: data.replaceSubrange(8..<16, with: SVC5Builder.littleEndian64(2501))
            case .sizeSmallerThanBody: data.replaceSubrange(8..<16, with: SVC5Builder.littleEndian64(2499))
            case .flippedCiphertextByte: data[32 + 4 + 12 + 5] ^= 0x01
            case .flippedTagByte: data[data.count - 1] ^= 0x01
            case .otherKey:
                data = try SVC5Builder.make(
                    plaintext: SVC5Builder.pattern(2500), chunkSize: 1000,
                    master: SymmetricKey(data: Data(repeating: 0x99, count: 32)))
            }
            return data
        }
    }

    @Test("A corrupted file fails decryptFile with decryptionFailed and leaves the destination untouched", arguments: Corruption.allCases)
    func corruptedFileFailsAndKeepsDestination(corruption: Corruption) throws {
        try withDirectory { directory in
            let valid = try SVC5Builder.make(plaintext: SVC5Builder.pattern(2500), chunkSize: 1000)
            let source = directory.appendingPathComponent("sealed")
            let destination = directory.appendingPathComponent("output")
            try corruption.apply(to: valid).write(to: source)
            let existing = Data("existing destination".utf8)
            try existing.write(to: destination)
            #expect(throws: VaultCryptoError.decryptionFailed) { try makeCipher().decryptFile(at: source, to: destination) }
            #expect(try Data(contentsOf: destination) == existing)
            #expect(try listing(directory) == ["output", "sealed"])
        }
    }

    @Test("A corrupted file fails decryptFile without creating a destination")
    func corruptedFileCreatesNoDestination() throws {
        try withDirectory { directory in
            var file = try SVC5Builder.make(plaintext: SVC5Builder.pattern(2500), chunkSize: 1000)
            file[file.count - 1] ^= 0x01
            let source = directory.appendingPathComponent("sealed")
            try file.write(to: source)
            let destination = directory.appendingPathComponent("output")
            #expect(throws: VaultCryptoError.decryptionFailed) { try makeCipher().decryptFile(at: source, to: destination) }
            #expect(try listing(directory) == ["sealed"])
        }
    }

    @Test("A corrupted file fails when decrypting onto itself and stays as it was")
    func corruptedInPlaceKeepsFile() throws {
        try withDirectory { directory in
            var file = try SVC5Builder.make(plaintext: SVC5Builder.pattern(2500), chunkSize: 1000)
            file[file.count - 1] ^= 0x01
            let url = directory.appendingPathComponent("file")
            try file.write(to: url)
            #expect(throws: VaultCryptoError.decryptionFailed) { try makeCipher().decryptFile(at: url, to: url) }
            #expect(try Data(contentsOf: url) == file)
        }
    }

    // MARK: streamInfo

    @Test("streamInfo reports the total size and chunk size of a file the cipher wrote")
    func streamInfoOfEncryptedFile() throws {
        try withDirectory { directory in
            let cipher = makeCipher()
            let source = directory.appendingPathComponent("plain")
            let sealed = directory.appendingPathComponent("sealed")
            try SVC5Builder.pattern(mebibyte + 10).write(to: source)
            try cipher.encryptFile(at: source, to: sealed)
            #expect(try cipher.streamInfo(of: sealed) == StreamInfo(totalSize: mebibyte + 10, chunkSize: mebibyte))
        }
    }

    @Test("streamInfo of an empty file's output reports size 0")
    func streamInfoOfEmptyFile() throws {
        try withDirectory { directory in
            let cipher = makeCipher()
            let source = directory.appendingPathComponent("plain")
            let sealed = directory.appendingPathComponent("sealed")
            try Data().write(to: source)
            try cipher.encryptFile(at: source, to: sealed)
            #expect(try cipher.streamInfo(of: sealed) == StreamInfo(totalSize: 0, chunkSize: mebibyte))
        }
    }

    @Test("streamInfo reads the header only, so a header with no body still reports")
    func streamInfoReadsHeaderOnly() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("headeronly")
            try SVC5Builder.header(chunkSize: 4096, totalSize: 123_456, fileID: Data(count: 16)).write(to: url)
            #expect(try makeCipher().streamInfo(of: url) == StreamInfo(totalSize: 123_456, chunkSize: 4096))
        }
    }

    @Test("streamInfo needs no key")
    func streamInfoWithoutKey() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("headeronly")
            try SVC5Builder.header(chunkSize: 4096, totalSize: 10, fileID: Data(count: 16)).write(to: url)
            #expect(try makeCipher(keyLoaded: false).streamInfo(of: url) == StreamInfo(totalSize: 10, chunkSize: 4096))
        }
    }

    @Test("streamInfo accepts chunk sizes 1 byte to 16 MiB", arguments: [1, 2, 1_048_576, 16_777_215, 16_777_216])
    func streamInfoAcceptsChunkSizeInRange(chunkSize: Int) throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("file")
            try SVC5Builder.header(chunkSize: chunkSize, totalSize: 5, fileID: Data(count: 16)).write(to: url)
            #expect(try makeCipher().streamInfo(of: url) == StreamInfo(totalSize: 5, chunkSize: chunkSize))
        }
    }

    @Test("streamInfo rejects chunk sizes of 0 and above 16 MiB", arguments: [0, 16_777_217, 100_000_000, 4_294_967_295])
    func streamInfoRejectsChunkSizeOutOfRange(chunkSize: Int) throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("file")
            try SVC5Builder.header(chunkSize: chunkSize, totalSize: 5, fileID: Data(count: 16)).write(to: url)
            #expect(throws: VaultCryptoError.decryptionFailed) { try makeCipher().streamInfo(of: url) }
        }
    }

    @Test("streamInfo accepts a total of exactly 2 TiB from a crafted header")
    func streamInfoAcceptsTwoTebibytes() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("file")
            let total = 2 * 1_099_511_627_776
            try SVC5Builder.header(chunkSize: mebibyte, totalSize: total, fileID: Data(count: 16)).write(to: url)
            #expect(try makeCipher().streamInfo(of: url) == StreamInfo(totalSize: total, chunkSize: mebibyte))
        }
    }

    @Test(
        "streamInfo rejects a total over 2 TiB from a crafted header",
        arguments: [UInt64(2_199_023_255_553), UInt64.max, UInt64(1) << 63])
    func streamInfoRejectsOverTwoTebibytes(total: UInt64) throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("file")
            var header = Data("SVC5".utf8)
            header.append(SVC5Builder.littleEndian32(UInt32(mebibyte)))
            header.append(SVC5Builder.littleEndian64(total))
            header.append(Data(count: 16))
            try header.write(to: url)
            #expect(throws: VaultCryptoError.decryptionFailed) { try makeCipher().streamInfo(of: url) }
        }
    }

    @Test("streamInfo rejects a bad magic")
    func streamInfoRejectsBadMagic() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("file")
            var header = SVC5Builder.header(chunkSize: mebibyte, totalSize: 5, fileID: Data(count: 16))
            header[3] = UInt8(ascii: "4")
            try header.write(to: url)
            #expect(throws: VaultCryptoError.decryptionFailed) { try makeCipher().streamInfo(of: url) }
        }
    }

    @Test("streamInfo rejects a truncated header", arguments: [0, 4, 16, 31])
    func streamInfoRejectsTruncatedHeader(length: Int) throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("file")
            let header = SVC5Builder.header(chunkSize: mebibyte, totalSize: 5, fileID: Data(count: 16))
            try Data(header.prefix(length)).write(to: url)
            #expect(throws: VaultCryptoError.decryptionFailed) { try makeCipher().streamInfo(of: url) }
        }
    }

    // MARK: decryptChunk

    private func builtFile(in directory: URL, plain: Data, chunkSize: Int = 1000) throws -> (url: URL, info: StreamInfo) {
        let url = directory.appendingPathComponent("sealed")
        try SVC5Builder.make(plaintext: plain, chunkSize: chunkSize).write(to: url)
        return (url, StreamInfo(totalSize: plain.count, chunkSize: chunkSize))
    }

    @Test("decryptChunk returns each chunk's plaintext, including the short last chunk")
    func decryptChunkInRange() throws {
        try withDirectory { directory in
            let plain = SVC5Builder.pattern(2500)
            let (url, info) = try builtFile(in: directory, plain: plain)
            let cipher = makeCipher()
            let streamed = try cipher.streamInfo(of: url)
            #expect(streamed == info)
            #expect(try cipher.decryptChunk(0, of: url, info: streamed) == plain.prefix(1000))
            #expect(try cipher.decryptChunk(1, of: url, info: streamed) == plain.subdata(in: 1000..<2000))
            #expect(try cipher.decryptChunk(2, of: url, info: streamed) == plain.suffix(500))
        }
    }

    @Test("decryptChunk handles a file whose size is an exact multiple of the chunk size")
    func decryptChunkExactMultiple() throws {
        try withDirectory { directory in
            let plain = SVC5Builder.pattern(2000)
            let (url, info) = try builtFile(in: directory, plain: plain)
            let cipher = makeCipher()
            #expect(try cipher.decryptChunk(1, of: url, info: info) == plain.suffix(1000))
            #expect(throws: VaultCryptoError.decryptionFailed) { try cipher.decryptChunk(2, of: url, info: info) }
        }
    }

    @Test("decryptChunk works on a file the cipher wrote, with 1 MiB chunks")
    func decryptChunkOfCipherOutput() throws {
        try withDirectory { directory in
            let cipher = makeCipher()
            let plain = SVC5Builder.pattern(mebibyte + 300)
            let source = directory.appendingPathComponent("plain")
            let sealed = directory.appendingPathComponent("sealed")
            try plain.write(to: source)
            try cipher.encryptFile(at: source, to: sealed)
            let info = try cipher.streamInfo(of: sealed)
            #expect(try cipher.decryptChunk(0, of: sealed, info: info) == plain.prefix(mebibyte))
            #expect(try cipher.decryptChunk(1, of: sealed, info: info) == plain.suffix(300))
        }
    }

    @Test("decryptChunk with an index out of range fails with decryptionFailed", arguments: [-1, 3, 4, 1_000_000, Int.max])
    func decryptChunkOutOfRange(index: Int) throws {
        try withDirectory { directory in
            let (url, info) = try builtFile(in: directory, plain: SVC5Builder.pattern(2500))
            #expect(throws: VaultCryptoError.decryptionFailed) { try makeCipher().decryptChunk(index, of: url, info: info) }
        }
    }

    @Test("decryptChunk fails on a tampered chunk but still reads its untouched neighbours")
    func decryptChunkTamperedChunk() throws {
        try withDirectory { directory in
            let plain = SVC5Builder.pattern(2500)
            var file = try SVC5Builder.make(plaintext: plain, chunkSize: 1000)
            let records = SVC5Builder.records(of: file)
            file[32 + records[0].count + 4 + 12 + 3] ^= 0x01
            let url = directory.appendingPathComponent("sealed")
            try file.write(to: url)
            let info = StreamInfo(totalSize: 2500, chunkSize: 1000)
            let cipher = makeCipher()
            #expect(throws: VaultCryptoError.decryptionFailed) { try cipher.decryptChunk(1, of: url, info: info) }
            #expect(try cipher.decryptChunk(0, of: url, info: info) == plain.prefix(1000))
            #expect(try cipher.decryptChunk(2, of: url, info: info) == plain.suffix(500))
        }
    }

    @Test("decryptChunk fails on a chunk moved to another index")
    func decryptChunkSwappedChunks() throws {
        try withDirectory { directory in
            let file = try SVC5Builder.make(plaintext: SVC5Builder.pattern(2500), chunkSize: 1000)
            let records = SVC5Builder.records(of: file)
            let url = directory.appendingPathComponent("sealed")
            try (SVC5Builder.slice(file, 0, 32) + records[1] + records[0] + records[2]).write(to: url)
            let info = StreamInfo(totalSize: 2500, chunkSize: 1000)
            #expect(throws: VaultCryptoError.decryptionFailed) { try makeCipher().decryptChunk(0, of: url, info: info) }
            #expect(throws: VaultCryptoError.decryptionFailed) { try makeCipher().decryptChunk(1, of: url, info: info) }
        }
    }

    @Test("decryptChunk fails on a file sealed with another key")
    func decryptChunkOtherKey() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("sealed")
            let other = SymmetricKey(data: Data(repeating: 0x99, count: 32))
            try SVC5Builder.make(plaintext: SVC5Builder.pattern(2500), chunkSize: 1000, master: other).write(to: url)
            let info = StreamInfo(totalSize: 2500, chunkSize: 1000)
            #expect(throws: VaultCryptoError.decryptionFailed) { try makeCipher().decryptChunk(0, of: url, info: info) }
        }
    }
}
