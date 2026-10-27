//
//  FileKindTests.swift
//  KoalaTVaultTests
//

import XCTest
@testable import KoalaTVault

final class FileKindTests: XCTestCase {

    // MARK: - Image
    func testJpgIsImage() { XCTAssertEqual(LegacyFileKind(extension: "jpg"), .image) }
    func testJpegIsImage() { XCTAssertEqual(LegacyFileKind(extension: "jpeg"), .image) }
    func testPngIsImage() { XCTAssertEqual(LegacyFileKind(extension: "png"), .image) }
    func testHeicIsImage() { XCTAssertEqual(LegacyFileKind(extension: "heic"), .image) }
    func testGifIsImage() { XCTAssertEqual(LegacyFileKind(extension: "gif"), .image) }
    func testWebpIsImage() { XCTAssertEqual(LegacyFileKind(extension: "webp"), .image) }

    // MARK: - Video
    func testMp4IsVideo() { XCTAssertEqual(LegacyFileKind(extension: "mp4"), .video) }
    func testMovIsVideo() { XCTAssertEqual(LegacyFileKind(extension: "mov"), .video) }
    func testM4vIsVideo() { XCTAssertEqual(LegacyFileKind(extension: "m4v"), .video) }

    // MARK: - Audio
    func testMp3IsAudio() { XCTAssertEqual(LegacyFileKind(extension: "mp3"), .audio) }
    func testM4aIsAudio() { XCTAssertEqual(LegacyFileKind(extension: "m4a"), .audio) }
    func testWavIsAudio() { XCTAssertEqual(LegacyFileKind(extension: "wav"), .audio) }
    func testAacIsAudio() { XCTAssertEqual(LegacyFileKind(extension: "aac"), .audio) }

    // MARK: - PDF
    func testPdfIsPdf() { XCTAssertEqual(LegacyFileKind(extension: "pdf"), .pdf) }

    // MARK: - Word
    func testDocIsWord() { XCTAssertEqual(LegacyFileKind(extension: "doc"), .word) }
    func testDocxIsWord() { XCTAssertEqual(LegacyFileKind(extension: "docx"), .word) }

    // MARK: - Spreadsheet
    func testXlsIsSpreadsheet() { XCTAssertEqual(LegacyFileKind(extension: "xls"), .spreadsheet) }
    func testXlsxIsSpreadsheet() { XCTAssertEqual(LegacyFileKind(extension: "xlsx"), .spreadsheet) }

    // MARK: - Presentation
    func testPptIsPresentation() { XCTAssertEqual(LegacyFileKind(extension: "ppt"), .presentation) }
    func testPptxIsPresentation() { XCTAssertEqual(LegacyFileKind(extension: "pptx"), .presentation) }

    // MARK: - Archive
    func testZipIsArchive() { XCTAssertEqual(LegacyFileKind(extension: "zip"), .archive) }
    func testRarIsArchive() { XCTAssertEqual(LegacyFileKind(extension: "rar"), .archive) }
    func test7zIsArchive() { XCTAssertEqual(LegacyFileKind(extension: "7z"), .archive) }

    // MARK: - Text
    func testTxtIsText() { XCTAssertEqual(LegacyFileKind(extension: "txt"), .text) }
    func testRtfIsText() { XCTAssertEqual(LegacyFileKind(extension: "rtf"), .text) }
    func testMdIsText() { XCTAssertEqual(LegacyFileKind(extension: "md"), .text) }

    // MARK: - Other
    func testUnknownExtensionIsOther() { XCTAssertEqual(LegacyFileKind(extension: "xyz"), .other) }
    func testEmptyExtensionIsOther() { XCTAssertEqual(LegacyFileKind(extension: ""), .other) }
    func testBinIsOther() { XCTAssertEqual(LegacyFileKind(extension: "bin"), .other) }
    func testHtmlIsOther() { XCTAssertEqual(LegacyFileKind(extension: "html"), .other) }

    // MARK: - Case insensitivity
    func testUppercaseJpgIsImage() { XCTAssertEqual(LegacyFileKind(extension: "JPG"), .image) }
    func testUppercaseMp4IsVideo() { XCTAssertEqual(LegacyFileKind(extension: "MP4"), .video) }
    func testUppercasePdfIsPdf() { XCTAssertEqual(LegacyFileKind(extension: "PDF"), .pdf) }
    func testMixedCaseDocxIsWord() { XCTAssertEqual(LegacyFileKind(extension: "DOCX"), .word) }
    func testMixedCaseMp3IsAudio() { XCTAssertEqual(LegacyFileKind(extension: "MP3"), .audio) }
    func testMixedCaseZipIsArchive() { XCTAssertEqual(LegacyFileKind(extension: "ZIP"), .archive) }
}
