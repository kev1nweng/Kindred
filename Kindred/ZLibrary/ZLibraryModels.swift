import Foundation

// MARK: - Book

struct ZLibraryBook: Identifiable, Hashable, Sendable {
    let id: String
    let isbn: String?
    let url: String
    let cover: String?
    let name: String
    let authors: [String]
    let publisher: String?
    let year: String?
    let language: String?
    let fileExtension: String
    let size: String?
    let rating: String?
    let quality: String?
}

// MARK: - Author

struct ZLibraryAuthor: Hashable, Sendable {
    let name: String
    let url: String
}

// MARK: - Book Detail

struct ZLibraryBookDetail: Sendable {
    let url: String
    let name: String
    let cover: String?
    let description: String?
    let authors: [ZLibraryAuthor]
    let year: String?
    let edition: String?
    let publisher: String?
    let language: String?
    let categories: String?
    let categoriesURL: String?
    let fileExtension: String
    let size: String?
    let rating: String?
    let downloadURL: String?
    let isbns: [String: String]
}

// MARK: - Search Filters

struct ZLibrarySearchFilters: Sendable {
    var exact: Bool = false
    var fromYear: Int? = nil
    var toYear: Int? = nil
    var languages: [String] = []
    var extensions: [String] = []

    static let defaultFilters = ZLibrarySearchFilters()
}

// MARK: - Search Result

struct ZLibrarySearchResult: Sendable {
    let books: [ZLibraryBook]
    let page: Int
    let totalPages: Int
    var hasMore: Bool { page < totalPages }
}

// MARK: - Download Limits

struct ZLibraryDownloadLimits: Sendable {
    let dailyAmount: Int
    let dailyAllowed: Int
    let dailyRemaining: Int
    let dailyReset: String
}

// MARK: - Sort Order

enum ZLibrarySortOrder: String, Sendable {
    case popular = "popular"
    case newest = "date_created"
    case recent = "date_updated"
}

// MARK: - Full Text Search Mode

enum ZLibraryFullTextMode: Sendable {
    case phrase
    case words
}