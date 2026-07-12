import Combine
import Foundation
import Network

@MainActor
final class HTTPBookServer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var address: String?
    @Published private(set) var statusMessage: String?
    @Published var errorMessage: String?

    private let library: BookLibrary
    private let queue = DispatchQueue(label: "com.kindred.http-server", qos: .userInitiated)
    private var listener: NWListener?

    init(library: BookLibrary) {
        self.library = library
    }

    func start() {
        guard listener == nil else { return }

        do {
            let listener = try NWListener(using: .tcp, on: .any)
            listener.service = NWListener.Service(name: "Kindred", type: "_http._tcp")
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard let port = listener?.port?.rawValue else { return }
                        self.isRunning = true
                        if let ip = LocalNetworkAddress.wifiIPv4 {
                            self.address = "http://\(ip):\(port)/"
                            self.statusMessage = String(localized: "Open this address in the Kindle browser. Keep Kindred open while downloading.")
                        } else {
                            self.address = "http://kindred.local:\(port)/"
                            self.statusMessage = String(localized: "No Wi-Fi IPv4 address was found. Connect both devices to the same Wi-Fi network.")
                        }
                    case .failed(let error):
                        self.errorMessage = error.localizedDescription
                        self.stop()
                    case .cancelled:
                        self.isRunning = false
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                Task { @MainActor in
                    let resources = self.library.books.map {
                        ServedBook(book: $0, fileURL: self.library.fileURL(for: $0))
                    }
                    self.queue.async {
                        HTTPConnection(connection: connection, books: resources).start()
                    }
                }
            }
            self.listener = listener
            statusMessage = String(localized: "Starting…")
            listener.start(queue: queue)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        address = nil
        statusMessage = nil
    }
}

private struct ServedBook: Sendable {
    let book: Book
    let fileURL: URL
}

private final class HTTPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let books: [ServedBook]

    init(connection: NWConnection, books: [ServedBook]) {
        self.connection = connection
        self.books = books
    }

    func start() {
        connection.stateUpdateHandler = { state in
            if case .ready = state { self.receiveRequest() }
            if case .failed = state { self.close() }
        }
        connection.start(queue: DispatchQueue(label: "com.kindred.http-connection"))
    }

    private func receiveRequest() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let request = String(data: data, encoding: .utf8) {
                self.respond(to: request)
            } else {
                self.sendError(status: "400 Bad Request", message: String(localized: "Invalid request"))
            }
            if error != nil { self.close() }
        }
    }

    private func respond(to request: String) {
        guard let requestLine = request.components(separatedBy: "\r\n").first else {
            return sendError(status: "400 Bad Request", message: String(localized: "Invalid request"))
        }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "GET" || parts[0] == "HEAD" else {
            return sendError(status: "405 Method Not Allowed", message: String(localized: "Only GET and HEAD are supported"))
        }
        let isHead = parts[0] == "HEAD"
        let components = URLComponents(string: parts[1])
        let path = components?.path ?? "/"
        let query = components?.queryItems?.first(where: { $0.name == "q" })?.value

        if path == "/" || path == "/index.html" {
            sendHTML(indexPage(query: query), headOnly: isHead)
            return
        }

        if path.hasPrefix("/books/"),
           let id = UUID(uuidString: String(path.dropFirst("/books/".count))),
           let item = books.first(where: { $0.book.id == id }) {
            sendFile(item, headOnly: isHead)
            return
        }

        sendError(status: "404 Not Found", message: String(localized: "Book not found"))
    }

    private func indexPage(query: String?) -> String {
        let normalizedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let visibleBooks = normalizedQuery.isEmpty ? books : books.filter {
            $0.book.title.localizedCaseInsensitiveContains(normalizedQuery)
                || $0.book.originalFilename.localizedCaseInsensitiveContains(normalizedQuery)
                || $0.book.format.localizedCaseInsensitiveContains(normalizedQuery)
        }
        let rows = visibleBooks.map { item in
            let title = escapeHTML(item.book.title)
            let filename = escapeHTML(item.book.originalFilename)
            let details = escapeHTML("\(item.book.format) · \(item.book.formattedSize)")
            return """
            <tr><td><a href="/books/\(item.book.id.uuidString)">\(title)</a><br><small>\(details)</small></td><td><a href="/books/\(item.book.id.uuidString)" download="\(filename)">\(escapeHTML(String(localized: "Download")))</a></td></tr>
            """
        }.joined(separator: "\n")

        let emptyMessage = normalizedQuery.isEmpty
            ? String(localized: "No books have been imported yet.")
            : String(localized: "No matching books were found.")
        let content = rows.isEmpty
            ? "<p>\(escapeHTML(emptyMessage))</p>"
            : "<table><tr><th>Book</th><th>File</th></tr>\(rows)</table>"
        let search = escapeHTML(String(localized: "Search"))
        let searchValue = escapeHTML(normalizedQuery)

        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>Kindred Library</title>
        <style type="text/css">body{font-family:Arial,sans-serif;margin:24px;color:#222}h1{font-size:26px}form{margin:18px 0}input{font-size:16px;padding:7px}input[type=text]{width:62%}table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:12px 8px;border-bottom:1px solid #aaa}a{color:#0645ad}small{color:#555}</style>
        </head><body><h1>\(escapeHTML(String(localized: "Kindred Library")))</h1><p>\(escapeHTML(String(localized: "Select a book to download it to your Kindle.")))</p><form action="/" method="get"><label for="q">\(search)</label><br><input type="text" id="q" name="q" value="\(searchValue)"> <input type="submit" value="\(search)"></form>\(content)<p><small>\(escapeHTML(String(localized: "Books are listed newest first.")))</small></p></body></html>
        """
    }

    private func sendHTML(_ html: String, headOnly: Bool) {
        let body = Data(html.utf8)
        let header = responseHeader(
            status: "200 OK",
            contentType: "text/html; charset=utf-8",
            contentLength: body.count,
            extra: "Cache-Control: no-cache\r\n"
        )
        let response = headOnly ? Data(header.utf8) : Data(header.utf8) + body
        sendFinal(response)
    }

    private func sendFile(_ item: ServedBook, headOnly: Bool) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: item.fileURL.path),
              let size = attributes[.size] as? NSNumber else {
            return sendError(status: "404 Not Found", message: String(localized: "File is unavailable"))
        }

        let dispositionName = item.book.originalFilename
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        let extra = "Content-Disposition: attachment; filename=\"\(dispositionName)\"\r\n"
            + "Cache-Control: no-cache\r\n"
        let header = responseHeader(
            status: "200 OK",
            contentType: contentType(for: item.book.format),
            contentLength: size.intValue,
            extra: extra
        )
        if headOnly {
            sendFinal(Data(header.utf8))
            return
        }

        do {
            let handle = try FileHandle(forReadingFrom: item.fileURL)
            sendFileHeader(Data(header.utf8), then: handle)
        } catch {
            close()
        }
    }

    private func sendFileHeader(_ header: Data, then handle: FileHandle) {
        connection.send(
            content: header,
            contentContext: .defaultMessage,
            isComplete: true,
            completion: .contentProcessed { [weak self] error in
                guard let self, error == nil else {
                    try? handle.close()
                    self?.close()
                    return
                }
                self.stream(handle)
            }
        )
    }

    private func stream(_ handle: FileHandle) {
        do {
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            guard !chunk.isEmpty else {
                try? handle.close()
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
                    self?.close()
                })
                return
            }
            connection.send(
                content: chunk,
                contentContext: .defaultMessage,
                isComplete: true,
                completion: .contentProcessed { [weak self] error in
                guard error == nil else {
                    try? handle.close()
                    self?.close()
                    return
                }
                self?.stream(handle)
            })
        } catch {
            try? handle.close()
            close()
        }
    }

    private func sendError(status: String, message: String) {
        let body = Data("<html><body><h1>\(escapeHTML(message))</h1></body></html>".utf8)
        let header = responseHeader(status: status, contentType: "text/html; charset=utf-8", contentLength: body.count)
        connection.send(content: Data(header.utf8) + body, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }

    private func sendFinal(_ data: Data) {
        connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }

    private func responseHeader(status: String, contentType: String, contentLength: Int, extra: String = "") -> String {
        "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(contentLength)\r\nConnection: close\r\n\(extra)\r\n"
    }

    private func close() {
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    private func contentType(for format: String) -> String {
        switch format {
        case "PDF": "application/pdf"
        case "TXT": "text/plain; charset=utf-8"
        case "MOBI": "application/x-mobipocket-ebook"
        default: "application/octet-stream"
        }
    }

    private func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

private enum LocalNetworkAddress {
    static var wifiIPv4: String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }

        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let item = interface.pointee
            guard String(cString: item.ifa_name) == "en0",
                  item.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            var address = item.ifa_addr.pointee
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                &address,
                socklen_t(item.ifa_addr.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if result == 0 { return String(cString: host) }
        }
        return nil
    }
}
