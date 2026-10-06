//
//  FileKindTests.swift
//  KoalaTVaultTests
//

import XCTest
@testable import KoalaTVault

final class FileKindTests: XCTestCase {

    // MARK: - Image
    func testJpgIsImage() { XCTAssertEqual(FileKind(extension: "jpg"), .image) }
    func testJpegIsImage() { XCTAssertEqual(FileKind(extension: "jpeg"), .image) }
    func testPngIsImage() { XCTAssertEqual(FileKind(extension: "png"), .image) }
    func testHeicIsImage() { XCTAssertEqual(FileKind(extension: "heic"), .image) }
    func testGifIsImage() { XCTAssertEqual(FileKind(extension: "gif"), .image) }
    func testWebpIsImage() { XCTAssertEqual(FileKind(extension: "webp"), .image) }

    // MARK: - Video
    func testMp4IsVideo() { XCTAssertEqual(FileKind(extension: "mp4"), .video) }
    func testMovIsVideo() { XCTAssertEqual(FileKind(extension: "mov"), .video) }
    func testM4vIsVideo() { XCTAssertEqual(FileKind(extension: "m4v"), .video) }

    // MARK: - Audio
    func testMp3IsAudio() { XCTAssertEqual(FileKind(extension: "mp3"), .audio) }
    func testM4aIsAudio() { XCTAssertEqual(FileKind(extension: "m4a"), .audio) }
    func testWavIsAudio() { XCTAssertEqual(FileKind(extension: "wav"), .audio) }
    func testAacIsAudio() { XCTAssertEqual(FileKind(extension: "aac"), .audio) }

    // MARK: - PDF
    func testPdfIsPdf() { XCTAssertEqual(FileKind(extension: "pdf"), .pdf) }

    // MARK: - Word
    func testDocIsWord() { XCTAssertEqual(FileKind(extension: "doc"), .word) }
    func testDocxIsWord() { XCTAssertEqual(FileKind(extension: "docx"), .word) }

    // MARK: - Spreadsheet
    func testXlsIsSpreadsheet() { XCTAssertEqual(FileKind(extension: "xls"), .spreadsheet) }
    func testXlsxIsSpreadsheet() { XCTAssertEqual(FileKind(extension: "xlsx"), .spreadsheet) }

    // MARK: - Presentation
    func testPptIsPresentation() { XCTAssertEqual(FileKind(extension: "ppt"), .presentation) }
    func testPptxIsPresentation() { XCTAssertEqual(FileKind(extension: "pptx"), .presentation) }

    // MARK: - Archive
    func testZipIsArchive() { XCTAssertEqual(FileKind(extension: "zip"), .archive) }
    func testRarIsArchive() { XCTAssertEqual(FileKind(extension: "rar"), .archive) }
    func test7zIsArchive() { XCTAssertEqual(FileKind(extension: "7z"), .archive) }

    // MARK: - Text
    func testTxtIsText() { XCTAssertEqual(FileKind(extension: "txt"), .text) }
    func testRtfIsText() { XCTAssertEqual(FileKind(extension: "rtf"), .text) }
    func testMdIsText() { XCTAssertEqual(FileKind(extension: "md"), .text) }

    // MARK: - Other
    func testUnknownExtensionIsOther() { XCTAssertEqual(FileKind(extension: "xyz"), .other) }
    func testEmptyExtensionIsOther() { XCTAssertEqual(FileKind(extension: ""), .other) }
    func testBinIsOther() { XCTAssertEqual(FileKind(extension: "bin"), .other) }
    func testHtmlIsOther() { XCTAssertEqual(FileKind(extension: "html"), .other) }

    // MARK: - Case insensitivity
    func testUppercaseJpgIsImage() { XCTAssertEqual(FileKind(extension: "JPG"), .image) }
    func testUppercaseMp4IsVideo() { XCTAssertEqual(FileKind(extension: "MP4"), .video) }
    func testUppercasePdfIsPdf() { XCTAssertEqual(FileKind(extension: "PDF"), .pdf) }
    func testMixedCaseDocxIsWord() { XCTAssertEqual(FileKind(extension: "DOCX"), .word) }
    func testMixedCaseMp3IsAudio() { XCTAssertEqual(FileKind(extension: "MP3"), .audio) }
    func testMixedCaseZipIsArchive() { XCTAssertEqual(FileKind(extension: "ZIP"), .archive) }
}
