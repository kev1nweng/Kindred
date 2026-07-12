import Foundation
import UniformTypeIdentifiers

struct Book: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let title: String
    let originalFilename: String
    let storedFilename: String
    let format: String
    let byteCount: Int64
    let importedAt: Date

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
}

enum BookFileType {
    static let azw3 = UTType(importedAs: "com.kindred.file.azw3", conformingTo: .data)
    static let azw = UTType(importedAs: "com.kindred.file.azw", conformingTo: .data)
    static let mobi = UTType(importedAs: "com.kindred.file.mobi", conformingTo: .data)
    static let supported: [UTType] = [azw3, azw, mobi, .pdf, .plainText]
    static let extensions = Set(["azw3", "azw", "mobi", "pdf", "txt"])
}
