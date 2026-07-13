import Foundation
import SwiftSoup

/// Parses ZLibrary HTML responses using SwiftSoup.
/// Ported from sertraline/zlibrary's BeautifulSoup-based parsing.
enum ZLibraryHTMLParser {

    // MARK: - Search Results

    /// Parse a search results page into books + total page count.
    static func parseSearchPage(_ html: String, mirror: String) throws -> (books: [ZLibraryBook], totalPages: Int) {
        let doc = try parse(html)

        // Check for "not found" notice
        if let notFound = try doc.select("div.notFound").first() {
            let text = try notFound.text()
            if !text.isEmpty {
                return ([], 0)
            }
        }

        guard let box = try doc.select("div#searchResultBox").first() else {
            throw ZLibraryError.parseError("Could not find searchResultBox")
        }

        let bookItems = try box.select("div.book-item")
        guard !bookItems.isEmpty else {
            throw ZLibraryError.parseError("Could not find any book-item elements")
        }

        var books: [ZLibraryBook] = []

        for bookElement in bookItems {
            guard let card = try bookElement.select("z-bookcard").first() else { continue }
            guard let coverImg = try card.select("img").first() else { continue }

            let id = try card.attr("id")
            let isbn = try card.attr("isbn").nilIfEmpty
            let href = try card.attr("href")
            let url = href.isEmpty ? "" : "\(mirror)\(href)"

            // Cover: prefer inner <img> data-src, fall back to outer img data-src
            let innerImg = try coverImg.select("img").first()
            let innerSrc = try? innerImg?.attr("data-src")
            let outerSrc = try? coverImg.attr("data-src")
            let cover = innerSrc ?? outerSrc
            let coverURL = cover?.nilIfEmpty

            let publisher = try card.attr("publisher").nilIfEmpty?.trimmingCharacters(in: .whitespaces)

            // Authors from div[slot="author"]
            var authors: [String] = []
            if let authorSlot = try card.select("div[slot=author]").first() {
                let authorText = try authorSlot.text()
                authors = authorText
                    .split(separator: ";")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }

            // Title from div[slot="title"]
            let title: String
            if let titleSlot = try card.select("div[slot=title]").first() {
                title = try titleSlot.text().trimmingCharacters(in: .whitespaces)
            } else {
                title = ""
            }

            guard !id.isEmpty || !title.isEmpty else { continue }

            let year = try card.attr("year").nilIfEmpty?.trimmingCharacters(in: .whitespaces)
            let language = try card.attr("language").nilIfEmpty?.trimmingCharacters(in: .whitespaces)
            let ext = try card.attr("extension").nilIfEmpty?.trimmingCharacters(in: .whitespaces) ?? ""
            let size = try card.attr("filesize").nilIfEmpty?.trimmingCharacters(in: .whitespaces)
            let rating = try card.attr("rating").nilIfEmpty?.trimmingCharacters(in: .whitespaces)
            let quality = try card.attr("quality").nilIfEmpty?.trimmingCharacters(in: .whitespaces)

            books.append(ZLibraryBook(
                id: id,
                isbn: isbn,
                url: url,
                cover: coverURL,
                name: title,
                authors: authors,
                publisher: publisher,
                year: year,
                language: language,
                fileExtension: ext,
                size: size,
                rating: rating,
                quality: quality
            ))
        }

        // Extract total pages from pager script
        let totalPages = try extractTotalPages(from: doc)

        return (books, totalPages)
    }

    // MARK: - Book Detail

    /// Parse a book detail page into full book info including download URL.
    static func parseBookDetail(_ html: String, mirror: String) throws -> ZLibraryBookDetail {
        let doc = try parse(html)

        guard let wrap = try doc.select("div.row.cardBooks").first() else {
            throw ZLibraryError.parseError("Failed to find book card container")
        }

        guard let zcover = try doc.select("z-cover").first() else {
            throw ZLibraryError.parseError("Failed to find z-cover element")
        }

        let url = try zcover.attr("href").nilIfEmpty ?? ""

        // Title - can be a list or single string
        let title: String
        let rawTitle = try zcover.attr("title")
        if rawTitle.isEmpty {
            title = ""
        } else {
            // z-cover title attribute may contain JSON array or plain string
            if rawTitle.hasPrefix("[") {
                // Try to parse as JSON array
                if let data = rawTitle.data(using: .utf8),
                   let arr = try? JSONSerialization.jsonObject(with: data) as? [String],
                   let first = arr.first {
                    title = first.trimmingCharacters(in: .whitespaces)
                } else {
                    title = rawTitle.trimmingCharacters(in: .whitespaces)
                }
            } else {
                title = rawTitle.trimmingCharacters(in: .whitespaces)
            }
        }

        // Cover image
        let cover: String? = {
            if let img = try? zcover.select("img.image").first(),
               let src = try? img.attr("src"),
               !src.isEmpty {
                return src
            }
            return nil
        }()

        // Authors
        var authors: [ZLibraryAuthor] = []
        if let col = try wrap.select("div.col-sm-9").first() {
            let anchors = try col.select("a")
            for anchor in anchors {
                let name = try anchor.text().trimmingCharacters(in: .whitespaces)
                let href = try anchor.attr("href")
                let authorURL = href.isEmpty ? "" : "\(mirror)\(href)"
                if !name.isEmpty {
                    authors.append(ZLibraryAuthor(name: name, url: authorURL))
                }
            }
        }

        // Description
        let description: String? = {
            if let descBox = try? wrap.select("div#bookDescriptionBox").first(),
               let text = try? descBox.text().trimmingCharacters(in: .whitespaces),
               !text.isEmpty {
                return text
            }
            return nil
        }()

        // Details box
        let details = try wrap.select("div.bookDetailsBox").first()

        func propertyValue(_ name: String) -> String? {
            guard let details else { return nil }
            guard let propDiv = try? details.select("div.property_\(name)").first() else { return nil }
            guard let valueDiv = try? propDiv.select("div.property_value").first() else { return nil }
            return try? valueDiv.text().trimmingCharacters(in: .whitespaces)
        }

        let year = propertyValue("year")
        let edition = propertyValue("edition")
        let publisher = propertyValue("publisher")
        let language = propertyValue("language")

        // ISBNs
        var isbns: [String: String] = [:]
        if let details, let isbnElements = try? details.select("div.property_isbn") {
            for isbnEl in isbnElements {
                if let labelDiv = try? isbnEl.select("div.property_label").first(),
                   let valueDiv = try? isbnEl.select("div.property_value").first() {
                    let label = (try? labelDiv.text())?.trimmingCharacters(in: CharacterSet(charactersIn: ":")) ?? ""
                    let value = (try? valueDiv.text())?.trimmingCharacters(in: .whitespaces) ?? ""
                    if !label.isEmpty && !value.isEmpty {
                        isbns[label] = value
                    }
                }
            }
        }

        // Categories
        var categories: String? = nil
        var categoriesURL: String? = nil
        if let details,
           let catDiv = try? details.select("div.property_categories").first(),
           let catValue = try? catDiv.select("div.property_value").first() {
            categories = try? catValue.text().trimmingCharacters(in: .whitespaces)
            if let link = try? catValue.select("a").first(),
               let href = try? link.attr("href"), !href.isEmpty {
                categoriesURL = "\(mirror)\(href)"
            }
        }

        // File info (extension + size)
        var fileExtension = ""
        var fileSize: String? = nil
        if let details,
           let fileDiv = try? details.select("div.property__file").first() {
            let fileText = try fileDiv.text().trimmingCharacters(in: .whitespaces)
            // Format: "EXT, SIZE" e.g. "PDF, 23.46 MB"
            let parts = fileText.split(separator: ",")
            if parts.count >= 2 {
                // Extension may have embedded newlines
                let extRaw = String(parts[0])
                let extParts = extRaw.split(separator: "\n")
                fileExtension = extParts.last?.trimmingCharacters(in: .whitespaces) ?? ""
                fileSize = String(parts[1]).trimmingCharacters(in: .whitespaces)
            } else {
                fileExtension = fileText
            }
        }

        // Rating
        let rating: String? = {
            if let ratingDiv = try? wrap.select("div.book-rating").first() {
                let text = (try? ratingDiv.text()) ?? ""
                let cleaned = text
                    .replacingOccurrences(of: "\n", with: "")
                    .split(separator: " ")
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                return cleaned.isEmpty ? nil : cleaned
            }
            return nil
        }()

        // Download URL
        var downloadURL: String? = nil
        if let dlBtn = try? doc.select("a.addDownloadedBook").first() {
            let btnText = (try? dlBtn.text()) ?? ""
            if btnText.lowercased().contains("unavailable") {
                downloadURL = nil // Mark as unavailable
            } else {
                let href = (try? dlBtn.attr("href")) ?? ""
                if !href.isEmpty {
                    downloadURL = "\(mirror)\(href)"
                }
            }
        }

        return ZLibraryBookDetail(
            url: url,
            name: title,
            cover: cover,
            description: description,
            authors: authors,
            year: year,
            edition: edition,
            publisher: publisher,
            language: language,
            categories: categories,
            categoriesURL: categoriesURL,
            fileExtension: fileExtension,
            size: fileSize,
            rating: rating,
            downloadURL: downloadURL,
            isbns: isbns
        )
    }

    // MARK: - Download Limits

    /// Parse the downloads page to extract daily download limits.
    static func parseDownloadLimits(_ html: String) throws -> ZLibraryDownloadLimits {
        let doc = try parse(html)

        guard let dstats = try doc.select("div.dstats-info").first() else {
            throw ZLibraryError.parseError("Could not find dstats-info div")
        }

        guard let dCount = try dstats.select("div.d-count").first() else {
            throw ZLibraryError.parseError("Could not find d-count div")
        }

        let countText = try dCount.text().trimmingCharacters(in: .whitespaces)
        let parts = countText.split(separator: "/")
        guard parts.count >= 2,
              let daily = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let allowed = Int(parts[1].trimmingCharacters(in: .whitespaces)) else {
            throw ZLibraryError.parseError("Could not parse download counts from: \(countText)")
        }

        var resetText = ""
        if let resetDiv = try dstats.select("div.d-reset").first() {
            resetText = (try? resetDiv.text().trimmingCharacters(in: .whitespaces)) ?? ""
        }

        return ZLibraryDownloadLimits(
            dailyAmount: daily,
            dailyAllowed: allowed,
            dailyRemaining: max(0, allowed - daily),
            dailyReset: resetText
        )
    }

    // MARK: - Helpers

    /// Extract total pages from the pager script in search results.
    private static func extractTotalPages(from doc: Document) throws -> Int {
        let scripts = try doc.select("script")
        for script in scripts {
            let text = try script.data()
            if text.contains("var pagerOptions") || text.contains("pagesTotal") {
                // Find "pagesTotal: N" pattern
                if let range = text.range(of: "pagesTotal:") {
                    let after = text[range.upperBound...]
                    // Extract the number after the colon
                    let trimmed = after.trimmingCharacters(in: .whitespaces)
                    if let endIdx = trimmed.firstIndex(where: { !$0.isNumber }) {
                        let numStr = String(trimmed[..<endIdx])
                        if let total = Int(numStr) {
                            return total
                        }
                    } else if let total = Int(trimmed) {
                        return total
                    }
                }
            }
        }
        return 1
    }
}

private extension String {
    var nilIfEmpty: String? {
        self.isEmpty ? nil : self
    }
}