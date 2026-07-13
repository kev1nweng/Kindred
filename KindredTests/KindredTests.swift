import XCTest
@testable import Kindred

final class KindredTests: XCTestCase {
    func testApplicationModuleLoads() {
        XCTAssertTrue(true)
    }

    func testKindleDownloadUsesASCIIFilenameForUnicodeBook() {
        let book = Book(
            id: UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!,
            title: "窄门",
            originalFilename: "窄门 (安德烈·纪德).mobi",
            storedFilename: "12345678-1234-1234-1234-123456789ABC.mobi",
            format: "MOBI",
            byteCount: 1,
            importedAt: Date(timeIntervalSince1970: 0)
        )

        let filename = KindleDownload.filename(for: book)

        XCTAssertEqual(filename, "kindred-12345678-1234-1234-1234-123456789abc.mobi")
        XCTAssertTrue(filename.unicodeScalars.allSatisfy(\.isASCII))
    }

    func testKindleDownloadExposesAZW3WithBrowserCompatibleExtension() {
        XCTAssertEqual(KindleDownload.downloadExtension(for: "AZW3"), "azw")
        XCTAssertEqual(KindleDownload.downloadExtension(for: "MOBI"), "mobi")
        XCTAssertEqual(KindleDownload.downloadExtension(for: "TXT"), "txt")
    }
}
