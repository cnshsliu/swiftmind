import XCTest
@testable import SwiftMindCore

final class NoteAssetsTests: XCTestCase {
    func testFolderNameStripsHTMLSuffix() {
        XCTAssertEqual(
            NoteAssets.folderName(forDocumentFileName: "报告.swiftmind.html"),
            "报告.swiftmind.assets"
        )
    }

    func testExternalizeReplacesDataURIWithARelativeFile() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01])
        let markdown = "![shot](data:image/png;base64,\(png.base64EncodedString()))"
        let result = NoteAssets.externalizeDataImages(in: markdown, folderName: "报告.swiftmind.assets")
        let name = NoteAssets.fileName(for: png, ext: "png")
        XCTAssertEqual(result.markdown, "![shot](报告.swiftmind.assets/\(name))")
        XCTAssertEqual(result.files.count, 1)
        XCTAssertEqual(result.files[0].data, png)
        XCTAssertFalse(result.markdown.contains("base64"))
    }

    func testSameBytesShareOneFile() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x00])
        let uri = "data:image/png;base64,\(png.base64EncodedString())"
        let markdown = "![](\(uri))\n![](\(uri))"
        let result = NoteAssets.externalizeDataImages(in: markdown, folderName: "A.swiftmind.assets")
        XCTAssertEqual(result.files.count, 1)
        XCTAssertEqual(result.markdown.components(separatedBy: result.files[0].relativePath).count, 3)
    }

    func testProseWithoutImagesIsUnchanged() {
        let markdown = "hello\nno picture"
        let result = NoteAssets.externalizeDataImages(in: markdown, folderName: "A.swiftmind.assets")
        XCTAssertEqual(result.markdown, markdown)
        XCTAssertTrue(result.files.isEmpty)
    }
}
