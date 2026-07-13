import Foundation
import Combine

@MainActor
final class BookLibrary: ObservableObject {
    private static let appGroup = "group.space.kev1nweng.kindred"
    @Published private(set) var books: [Book] = []
    @Published var errorMessage: String?

    private let fileManager = FileManager.default
    private let booksDirectory: URL
    private let metadataURL: URL
    private let inboxDirectory: URL?

    init() {
        let legacySupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kindred", isDirectory: true)
        let groupContainer = fileManager.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup)
        let support = groupContainer?
            .appendingPathComponent("Library/Application Support/Kindred", isDirectory: true)
            ?? legacySupport
        booksDirectory = support.appendingPathComponent("Books", isDirectory: true)
        metadataURL = support.appendingPathComponent("library.json")
        inboxDirectory = groupContainer?.appendingPathComponent("Inbox", isDirectory: true)

        do {
            try fileManager.createDirectory(at: booksDirectory, withIntermediateDirectories: true)
            if support != legacySupport {
                try migrateLibraryIfNeeded(from: legacySupport)
            }
            try load()
            importPendingShares()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importBooks(from urls: [URL]) {
        var failures: [String] = []

        for sourceURL in urls {
            let accessed = sourceURL.startAccessingSecurityScopedResource()
            defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }

            do {
                try importBook(from: sourceURL)
            } catch {
                failures.append("\(sourceURL.lastPathComponent): \(error.localizedDescription)")
            }
        }

        books.sort { $0.importedAt > $1.importedAt }
        do { try save() } catch { failures.append(error.localizedDescription) }
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
    }

    func delete(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            delete(books[index], saveAfterwards: false)
        }
        do { try save() } catch { errorMessage = error.localizedDescription }
    }

    func delete(_ book: Book) {
        delete(book, saveAfterwards: true)
    }

    func rename(_ book: Book, to newTitle: String) {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let index = books.firstIndex(where: { $0.id == book.id }) else { return }

        let fileExtension = (book.originalFilename as NSString).pathExtension
        let filename = fileExtension.isEmpty ? title : "\(title).\(fileExtension)"
        books[index] = Book(
            id: book.id,
            title: title,
            originalFilename: filename,
            storedFilename: book.storedFilename,
            format: book.format,
            byteCount: book.byteCount,
            importedAt: book.importedAt
        )
        do { try save() } catch { errorMessage = error.localizedDescription }
    }

    func fileURL(for book: Book) -> URL {
        booksDirectory.appendingPathComponent(book.storedFilename)
    }

    func present(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    func importPendingShares() {
        guard let inboxDirectory,
              let itemDirectories = try? fileManager.contentsOfDirectory(
                at: inboxDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ), !itemDirectories.isEmpty else { return }

        var failures: [String] = []
        var importedAny = false
        for itemDirectory in itemDirectories {
            do {
                let files = try fileManager.contentsOfDirectory(
                    at: itemDirectory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
                for file in files {
                    do {
                        try importBook(from: file)
                        importedAny = true
                    } catch {
                        failures.append("\(file.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                try fileManager.removeItem(at: itemDirectory)
            } catch {
                failures.append(error.localizedDescription)
            }
        }

        if importedAny {
            books.sort { $0.importedAt > $1.importedAt }
            do { try save() } catch { failures.append(error.localizedDescription) }
        }
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
    }

    private func delete(_ book: Book, saveAfterwards: Bool) {
        try? fileManager.removeItem(at: fileURL(for: book))
        books.removeAll { $0.id == book.id }
        if saveAfterwards {
            do { try save() } catch { errorMessage = error.localizedDescription }
        }
    }

    private func importBook(from sourceURL: URL) throws {
        let ext = sourceURL.pathExtension.lowercased()
        guard BookFileType.extensions.contains(ext) else {
            throw LibraryError.unsupportedFormat(ext.isEmpty ? "unknown" : ext)
        }

        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw LibraryError.notAFile }

        let id = UUID()
        let storedFilename = "\(id.uuidString).\(ext)"
        let destination = booksDirectory.appendingPathComponent(storedFilename)
        try fileManager.copyItem(at: sourceURL, to: destination)

        let filename = sourceURL.lastPathComponent
        let title = sourceURL.deletingPathExtension().lastPathComponent
        books.append(Book(
            id: id,
            title: title.isEmpty ? filename : title,
            originalFilename: filename,
            storedFilename: storedFilename,
            format: ext.uppercased(),
            byteCount: Int64(values.fileSize ?? 0),
            importedAt: Date()
        ))
    }

    private func load() throws {
        guard fileManager.fileExists(atPath: metadataURL.path) else { return }
        let data = try Data(contentsOf: metadataURL)
        books = try JSONDecoder().decode([Book].self, from: data)
            .filter { fileManager.fileExists(atPath: fileURL(for: $0).path) }
            .sorted { $0.importedAt > $1.importedAt }
    }

    private func save() throws {
        let data = try JSONEncoder().encode(books)
        try data.write(to: metadataURL, options: .atomic)
    }

    private func migrateLibraryIfNeeded(from legacySupport: URL) throws {
        let legacyMetadata = legacySupport.appendingPathComponent("library.json")
        guard !fileManager.fileExists(atPath: metadataURL.path),
              fileManager.fileExists(atPath: legacyMetadata.path) else { return }

        let legacyBooks = legacySupport.appendingPathComponent("Books", isDirectory: true)
        if fileManager.fileExists(atPath: legacyBooks.path) {
            for file in try fileManager.contentsOfDirectory(
                at: legacyBooks,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) {
                try fileManager.copyItem(at: file, to: booksDirectory.appendingPathComponent(file.lastPathComponent))
            }
        }
        try fileManager.copyItem(at: legacyMetadata, to: metadataURL)
    }
}

private enum LibraryError: LocalizedError {
    case unsupportedFormat(String)
    case notAFile

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            String(format: String(localized: "Unsupported file type: %@"), ext)
        case .notAFile:
            String(localized: "The selected item is not a regular file.")
        }
    }
}
