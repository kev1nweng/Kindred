import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private static let appGroup = "group.space.kev1nweng.kindred"
    private static let supportedExtensions = Set(["azw3", "azw", "mobi", "pdf", "txt"])
    private var hasStarted = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasStarted else { return }
        hasStarted = true
        importSharedFiles()
    }

    private func importSharedFiles() {
        let providers = extensionContext?.inputItems
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] } ?? []

        guard !providers.isEmpty else {
            showError(title: String(localized: "Import Failed"), message: String(localized: "No files were shared."))
            return
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var unsupportedNames: [String] = []
        var failures: [String] = []
        var importedCount = 0

        for provider in providers {
            guard let typeIdentifier = preferredTypeIdentifier(for: provider) else {
                unsupportedNames.append(provider.suggestedName ?? String(localized: "Unknown file"))
                continue
            }

            group.enter()
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] url, error in
                defer { group.leave() }
                guard let self else { return }
                guard let url else {
                    lock.withLock { failures.append(error?.localizedDescription ?? String(localized: "Unable to read the shared file.")) }
                    return
                }

                let filename = self.filename(for: provider, sourceURL: url, typeIdentifier: typeIdentifier)
                let fileExtension = (filename as NSString).pathExtension.lowercased()
                guard Self.supportedExtensions.contains(fileExtension) else {
                    lock.withLock { unsupportedNames.append(filename) }
                    return
                }

                do {
                    try self.copyToInbox(sourceURL: url, filename: filename)
                    lock.withLock { importedCount += 1 }
                } catch {
                    lock.withLock { failures.append("\(filename): \(error.localizedDescription)") }
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            if !unsupportedNames.isEmpty {
                let names = unsupportedNames.joined(separator: "\n")
                self.showError(
                    title: String(localized: "Unsupported File Format"),
                    message: String(format: String(localized: "Kindred cannot import:\n%@"), names)
                )
            } else if !failures.isEmpty || importedCount == 0 {
                self.showError(
                    title: String(localized: "Import Failed"),
                    message: failures.joined(separator: "\n")
                )
            } else {
                self.extensionContext?.completeRequest(returningItems: nil)
            }
        }
    }

    private func preferredTypeIdentifier(for provider: NSItemProvider) -> String? {
        provider.registeredTypeIdentifiers.first { identifier in
            UTType(identifier)?.conforms(to: .data) == true
        } ?? provider.registeredTypeIdentifiers.first
    }

    private func filename(for provider: NSItemProvider, sourceURL: URL, typeIdentifier: String) -> String {
        var name = provider.suggestedName ?? sourceURL.lastPathComponent
        guard (name as NSString).pathExtension.isEmpty,
              let fileExtension = UTType(typeIdentifier)?.preferredFilenameExtension else { return name }
        name += ".\(fileExtension)"
        return name
    }

    private func copyToInbox(sourceURL: URL, filename: String) throws {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroup
        ) else {
            throw ShareError.appGroupUnavailable
        }
        let itemDirectory = container
            .appendingPathComponent("Inbox", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: itemDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sourceURL, to: itemDirectory.appendingPathComponent(filename))
    }

    private func showError(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default) { [weak self] _ in
            self?.extensionContext?.completeRequest(returningItems: nil)
        })
        present(alert, animated: true)
    }
}

private enum ShareError: LocalizedError {
    case appGroupUnavailable

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable: String(localized: "The shared container is unavailable.")
        }
    }
}

private extension NSLock {
    func withLock(_ action: () -> Void) {
        lock()
        defer { unlock() }
        action()
    }
}
