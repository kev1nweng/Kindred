import Foundation

enum ZLibraryError: LocalizedError {
    case loginFailed(String)
    case notLoggedIn
    case emptyQuery
    case noDomain
    case parseError(String)
    case bookNotFound(String)
    case downloadUnavailable
    case networkError(Error)
    case invalidResponse
    case unsupportedFormat(String)

    var errorDescription: String? {
        switch self {
        case .loginFailed(let detail):
            "ZLibrary login failed: \(detail)"
        case .notLoggedIn:
            "Not logged in to ZLibrary. Call login() first."
        case .emptyQuery:
            "Search query is empty."
        case .noDomain:
            "No working ZLibrary domains found. Try again later."
        case .parseError(let detail):
            "Failed to parse ZLibrary response: \(detail)"
        case .bookNotFound(let id):
            "Book not found: \(id)"
        case .downloadUnavailable:
            "Download is unavailable for this book."
        case .networkError(let error):
            "Network error: \(error.localizedDescription)"
        case .invalidResponse:
            "Invalid response from ZLibrary server."
        case .unsupportedFormat(let ext):
            "Unsupported file format: \(ext)"
        }
    }
}