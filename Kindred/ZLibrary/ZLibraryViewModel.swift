import Foundation
import SwiftUI

/// SwiftUI-facing wrapper for ZLibrary state.
/// Tracks page loading and download progress for reactive UI.
@MainActor
final class ZLibraryViewModel: ObservableObject {
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var downloadStatus: DownloadStatus?
    @Published var downloadProgress: Double = 0

    enum DownloadStatus: Equatable {
        case downloading(String)
        case importing(String)
        case success(String)
        case failed(String)
    }

    // MARK: - Page loading

    func setLoading(_ loading: Bool) {
        isLoading = loading
    }

    // MARK: - Download flow

    func downloadStarted(filename: String) {
        downloadProgress = 0
        withAnimation(.snappy) {
            downloadStatus = .downloading(filename)
        }
    }

    func updateDownloadProgress(_ progress: Double) {
        downloadProgress = progress
    }

    func handleDownloadedFile(at url: URL, title: String, library: BookLibrary) {
        let ext = url.pathExtension.lowercased()
        guard BookFileType.extensions.contains(ext) else {
            downloadStatus = .failed("Unsupported format: .\(ext)")
            errorMessage = "Unsupported format: .\(ext)"
            return
        }

        withAnimation(.snappy) {
            downloadStatus = .importing(title)
        }
        library.importDownloadedBook(from: url, preferredTitle: title)
        try? FileManager.default.removeItem(at: url)
        withAnimation(.snappy) {
            downloadStatus = .success(title)
        }
    }

    func dismissDownloadStatus() {
        withAnimation(.snappy) {
            downloadStatus = nil
            downloadProgress = 0
        }
    }
}