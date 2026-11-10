import CryptoKit
import Foundation
import Testing

@testable import KoalaTVault

/// Independent, CryptoKit-only builder and reader of SVC5 files, written from the memo's layout.
enum SVC5Builder {
    static let headerLength = 32
    static let overhead = 28
    static let mebibyte = 1_048_576
    static let masterKey = SymmetricKey(data: Data(repeating: 0x2A, count: 32))

    static func littleEndian32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    static func littleEndian64(_ value: UInt64) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    static func readLittleEndian(_ data: Data, at offset: Int, count: Int) -> UInt64 {
        var result: UInt64 = 0
        for position in 0..<count {
            result |= UInt64(data[data.startIndex + offset + position]) << UInt64(8 * position)
        }
        return result
    }

    static func slice(_ data: Data, _ offset: Int, _ count: Int) -> Data {
        Data(data[(data.startIndex + offset)..<(data.startIndex + offset + count)])
    }

    static func header(chunkSize: Int, totalSize: Int, fileID: Data) -> Data {
        var header = Data("SVC5".utf8)
        header.append(littleEndian32(UInt32(chunkSize)))
        header.append(littleEndian64(UInt64(totalSize)))
        header.append(fileID)
        return header
    }

    static func fileKey(master: SymmetricKey = masterKey, fileID: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: master, salt: fileID, info: Data("file-key".utf8), outputByteCount: 32)
    }

    static func record(plain: Data, header: Data, index: Int, key: SymmetricKey) throws -> Data {
        var aad = header
        aad.append(littleEndian64(UInt64(index)))
        let sealed = try AES.GCM.seal(plain, using: key, authenticating: aad)
        guard let combined = sealed.combined else { throw VaultCryptoError.encryptionFailed }
        var record = littleEndian32(UInt32(combined.count))
        record.append(combined)
        return record
    }

    /// The records of a built file, as separate `[length | combined]` blobs.
    static func records(of file: Data) -> [Data] {
        var result: [Data] = []
        var offset = headerLength
        while offset + 4 <= file.count {
            let length = Int(readLittleEndian(file, at: offset, count: 4))
            result.append(slice(file, offset, 4 + length))
            offset += 4 + length
        }
        return result
    }

    static func make(
        plaintext: Data, chunkSize: Int, fileID: Data = Data(repeating: 0x11, count: 16),
        master: SymmetricKey = masterKey
    ) throws -> Data {
        let header = header(chunkSize: chunkSize, totalSize: plaintext.count, fileID: fileID)
        let key = fileKey(master: master, fileID: fileID)
        var file = header
        var index = 0
        var offset = 0
        while offset < plaintext.count {
            let count = min(chunkSize, plaintext.count - offset)
            file.append(try record(plain: slice(plaintext, offset, count), header: header, index: index, key: key))
            index += 1
            offset += count
        }
        return file
    }

    static func pattern(_ count: Int, seed: Int = 7) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ seed) })
    }

    static func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// SVC5 layout, checked byte by byte through the live cipher (SVC5Format's own API is not part of the contract).
@Suite struct SVC5FormatTests {
    private let cipher = LiveFileCipher(keyStore: MockMasterKeyStoring(keyLoaded: true))

    private func encrypted(_ plaintext: Data) throws -> Data {
        let directory = try SVC5Builder.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("plain")
        let destination = directory.appendingPathComponent("sealed")
        try plaintext.write(to: source)
        try cipher.encryptFile(at: source, to: destination)
        return try Data(contentsOf: destination)
    }

    @Test("An encrypted file starts with the SVC5 magic")
    func writesMagic() throws {
        let file = try encrypted(SVC5Builder.pattern(100))
        #expect(SVC5Builder.slice(file, 0, 4) == Data("SVC5".utf8))
    }

    @Test("The header stores a 1 MiB chunk size as UInt32 little endian")
    func writesChunkSize() throws {
        let file = try encrypted(SVC5Builder.pattern(100))
        #expect(SVC5Builder.slice(file, 4, 4) == Data([0x00, 0x00, 0x10, 0x00]))
    }

    @Test("The header stores the plaintext size as UInt64 little endian")
    func writesPlaintextSize() throws {
        let file = try encrypted(SVC5Builder.pattern(0x0102_03))
        #expect(SVC5Builder.slice(file, 8, 8) == Data([0x03, 0x02, 0x01, 0, 0, 0, 0, 0]))
    }

    @Test("The header is 32 bytes and a small file is one length-prefixed AES-GCM record after it")
    func smallFileLayout() throws {
        let file = try encrypted(SVC5Builder.pattern(100))
        #expect(file.count == 32 + 4 + 12 + 100 + 16)
        #expect(SVC5Builder.readLittleEndian(file, at: 32, count: 4) == 128)
    }

    @Test("An empty file encrypts to the header only")
    func emptyFileIsHeaderOnly() throws {
        let file = try encrypted(Data())
        #expect(file.count == 32)
        #expect(SVC5Builder.slice(file, 0, 4) == Data("SVC5".utf8))
        #expect(SVC5Builder.readLittleEndian(file, at: 8, count: 8) == 0)
    }

    @Test("A file of exactly 1 MiB is a single chunk")
    func exactlyOneMebibyteIsOneChunk() throws {
        let file = try encrypted(SVC5Builder.pattern(SVC5Builder.mebibyte))
        #expect(file.count == 32 + 4 + SVC5Builder.mebibyte + 28)
        #expect(SVC5Builder.records(of: file).count == 1)
    }

    @Test("One byte over 1 MiB makes a second, 1-byte chunk")
    func oneByteOverMebibyteIsTwoChunks() throws {
        let file = try encrypted(SVC5Builder.pattern(SVC5Builder.mebibyte + 1))
        let records = SVC5Builder.records(of: file)
        #expect(records.count == 2)
        #expect(SVC5Builder.readLittleEndian(records[0], at: 0, count: 4) == UInt64(SVC5Builder.mebibyte + 28))
        #expect(SVC5Builder.readLittleEndian(records[1], at: 0, count: 4) == 29)
        #expect(file.count == 32 + 4 + SVC5Builder.mebibyte + 28 + 4 + 1 + 28)
    }

    @Test("Each chunk opens with the HKDF file key and header plus chunk index as AAD")
    func chunksOpenWithIndependentlyDerivedKey() throws {
        let plaintext = SVC5Builder.pattern(SVC5Builder.mebibyte * 2 + 5)
        let file = try encrypted(plaintext)
        let header = SVC5Builder.slice(file, 0, 32)
        let fileID = SVC5Builder.slice(file, 16, 16)
        let key = SVC5Builder.fileKey(fileID: fileID)
        let records = SVC5Builder.records(of: file)
        #expect(records.count == 3)
        var recovered = Data()
        for (index, record) in records.enumerated() {
            var aad = header
            aad.append(SVC5Builder.littleEndian64(UInt64(index)))
            let box = try AES.GCM.SealedBox(combined: SVC5Builder.slice(record, 4, record.count - 4))
            recovered.append(try AES.GCM.open(box, using: key, authenticating: aad))
        }
        #expect(recovered == plaintext)
    }

    @Test("The file ID is random per file")
    func fileIDIsRandomPerFile() throws {
        let first = try encrypted(SVC5Builder.pattern(10))
        let second = try encrypted(SVC5Builder.pattern(10))
        #expect(SVC5Builder.slice(first, 16, 16) != SVC5Builder.slice(second, 16, 16))
    }

    @Test("Every chunk gets its own random nonce")
    func nonceDiffersPerChunk() throws {
        let file = try encrypted(Data(repeating: 0x55, count: SVC5Builder.mebibyte * 2))
        let records = SVC5Builder.records(of: file)
        #expect(records.count == 2)
        #expect(SVC5Builder.slice(records[0], 4, 12) != SVC5Builder.slice(records[1], 4, 12))
    }

    @Test("Existing files written with other chunk sizes stay readable")
    func readsIndependentlyBuiltFiles() throws {
        let directory = try SVC5Builder.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for chunkSize in [1, 1000, SVC5Builder.mebibyte] {
            let plaintext = SVC5Builder.pattern(chunkSize == 1 ? 5 : 2500)
            let source = directory.appendingPathComponent("built\(chunkSize)")
            let output = directory.appendingPathComponent("out\(chunkSize)")
            try SVC5Builder.make(plaintext: plaintext, chunkSize: chunkSize).write(to: source)
            try cipher.decryptFile(at: source, to: output)
            #expect(try Data(contentsOf: output) == plaintext)
        }
    }

    @Test("An independently built empty (header-only) file decrypts to an empty file")
    func readsHeaderOnlyFile() throws {
        let directory = try SVC5Builder.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("empty")
        let output = directory.appendingPathComponent("out")
        try SVC5Builder.make(plaintext: Data(), chunkSize: SVC5Builder.mebibyte).write(to: source)
        try cipher.decryptFile(at: source, to: output)
        #expect(try Data(contentsOf: output).isEmpty)
    }
}
