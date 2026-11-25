import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

// What another app shared, read into one item for the inbox: a link, a text, pictures, or a
// mix. The pictures are copied as files into the drop's draft folder as they arrive and never
// decoded here beyond a small preview, because an extension has little memory.
@Observable
final class Share {
    enum Phase: Equatable {
        case loading
        case ready
        // The app is not paired, so there is no inbox to add to.
        case unpaired
        // Nothing Pendenz can take: no link, text or picture.
        case empty
        case failed
    }

    struct Picture: Identifiable {
        let id: String
        let preview: CGImage?
    }

    private(set) var phase = Phase.loading
    var title = "" {
        didSet {
            let cut = title.cutToServerLength(SharedDrops.titleLimit)
            if cut != title { title = cut }
        }
    }

    private(set) var link: URL?
    // The whole text, kept as the item's description when it says more than the title.
    private(set) var text: String?
    private(set) var pictures: [Picture] = []
    // Said under the content: what was left out.
    private(set) var notice: String?

    private let id = UUID().uuidString
    private var pairing: SharedPairing?

    var canAdd: Bool {
        [.ready, .failed].contains(phase) && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Reading

    func load(_ items: [NSExtensionItem]) async {
        guard let pairing = SharedDrops.pairing() else {
            phase = .unpaired
            return
        }
        self.pairing = pairing
        var texts: [String] = []
        var pageTitle: String?
        var links: [URL] = []
        var tooLarge = 0
        var unread = 0
        var tooMany = 0
        let draft = SharedDrops.draftFolder(for: id)

        for item in items {
            if let content = item.attributedContentText?.string { texts.append(content) }
            if let title = item.attributedTitle?.string { pageTitle = pageTitle ?? title }
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    guard pictures.count < SharedDrops.pictureLimit else {
                        tooMany += 1
                        continue
                    }
                    guard let draft else {
                        unread += 1
                        continue
                    }
                    let name = "Picture-\(pictures.count + 1)"
                    switch await Self.copyPicture(from: provider, into: draft, named: name) {
                    case .copied(let file, let preview): pictures.append(Picture(id: file, preview: preview))
                    case .tooLarge: tooLarge += 1
                    case .unread: unread += 1
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    if let url = await Self.loadURL(from: provider) { links.append(url) }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                          let text = await Self.loadText(from: provider) { texts.append(text) }
            }
        }

        // An app may share its link as text as well, or as text alone.
        var kept: [String] = []
        for text in texts.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !text.isEmpty {
            if let url = Self.webLink(text) {
                links.append(url)
            } else if !kept.contains(text) {
                kept.append(text)
            }
        }
        // The server counts the link in bytes.
        link = links.first { $0.absoluteString.utf8.count <= SharedDrops.linkLimit }
        if link == nil, !links.isEmpty {
            notice = "The link is too long to keep. A link can have up to 2,000 characters."
        }
        // Cut here already: the sheet keeps it in memory, and the description holds no more.
        let text = kept.joined(separator: "\n\n").cutToServerLength(SharedDrops.descriptionLimit)
        self.text = text.isEmpty ? nil : text

        if let text = self.text {
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            title = line.trimmingCharacters(in: .whitespaces).cutToServerLength(SharedDrops.titleLimit)
        } else if let link {
            let page = pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            title = page.isEmpty ? (link.host() ?? link.absoluteString) : page
        } else if !pictures.isEmpty {
            title = pictures.count == 1 ? "Image" : "\(pictures.count) Images"
        }

        var left: [String] = []
        if tooLarge == 1 { left.append("An image larger than 50 MB was left out.") }
        if tooLarge > 1 { left.append("\(tooLarge) images larger than 50 MB were left out.") }
        if unread >
            0 { left.append(unread == 1 ? "An image could not be read." : "\(unread) images could not be read.") }
        if tooMany > 0 { left.append("Only the first \(SharedDrops.pictureLimit) images are added.") }
        if !left.isEmpty { notice = ([notice].compactMap(\.self) + left).joined(separator: " ") }

        phase = link == nil && self.text == nil && pictures.isEmpty ? .empty : .ready
    }

    // MARK: Saving

    // Leaves the drop for the app. False when it could not be written; the sheet then says so.
    func save() -> Bool {
        guard canAdd, let pairing else { return false }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // The description keeps the text whenever the title does not say all of it: a text of
        // several lines, a long line that was cut, or a title that was changed.
        let description = text.flatMap { $0 == title ? nil : $0 }
        let drop = SharedDrop(
            id: id,
            server: pairing.server,
            title: title,
            description: description,
            link: link?.absoluteString,
            pictures: pictures.map(\.id),
            createdAt: .now,
        )
        guard SharedDrops.finish(drop) else {
            // Unpaired while the sheet was open: there is no inbox to add to any more.
            phase = SharedDrops.pairing()?.server == pairing.server ? .failed : .unpaired
            return false
        }
        SharedDrops.announce()
        return true
    }

    func discard() {
        SharedDrops.discardDraft(id)
    }

    // MARK: Providers

    // A text that is one web address and nothing else.
    private static func webLink(_ text: String) -> URL? {
        guard !text.contains(where: \.isWhitespace), let url = URL(string: text), isWebLink(url) else { return nil }
        return url
    }

    // A link the server takes: http or https, with a host and a port it can parse. One it
    // refuses would cost the whole share, its text and pictures too.
    private static func isWebLink(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host(), !host.isEmpty,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return false }
        return parts.port.map { (0 ... 65535).contains($0) } ?? true
    }

    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        let url: URL? = await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
        guard let url, isWebLink(url) else { return nil }
        return url
    }

    private static func loadText(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { text, _ in continuation.resume(returning: text) }
        }
    }

    private enum Copied {
        case copied(String, CGImage?)
        case tooLarge
        case unread
    }

    // The picture as a file in the drop's folder, byte for byte; the app scales it. Copied
    // inside the callback, because the provider's file is gone once it returns.
    private nonisolated static func copyPicture(
        from provider: NSItemProvider, into folder: URL, named name: String,
    ) async -> Copied {
        let copied: Copied? = await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(for: .image, openInPlace: false) { url, _, _ in
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }
                let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension.lowercased()
                let file = "\(name).\(ext)"
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                guard size <= SharedDrops.pictureBytesLimit else {
                    continuation.resume(returning: .tooLarge)
                    return
                }
                let destination = folder.appending(path: file)
                guard (try? FileManager.default.copyItem(at: url, to: destination)) != nil else {
                    continuation.resume(returning: .unread)
                    return
                }
                continuation.resume(returning: .copied(file, preview(of: destination)))
            }
        }
        if let copied { return copied }
        // Some apps hand over a picture only as data, such as a screenshot just taken.
        return await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(for: .image) { data, _ in
                guard let data else {
                    continuation.resume(returning: .unread)
                    return
                }
                guard data.count <= SharedDrops.pictureBytesLimit else {
                    continuation.resume(returning: .tooLarge)
                    return
                }
                let type = CGImageSourceCreateWithData(data as CFData, nil).flatMap(CGImageSourceGetType)
                let ext = (type as String?).flatMap { UTType($0)?.preferredFilenameExtension } ?? "jpg"
                let destination = folder.appending(path: "\(name).\(ext)")
                guard (try? data.write(to: destination, options: .atomic)) != nil else {
                    continuation.resume(returning: .unread)
                    return
                }
                continuation.resume(returning: .copied(destination.lastPathComponent, preview(of: destination)))
            }
        }
    }

    // A small preview, read without decoding the whole picture.
    private nonisolated static func preview(of file: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 240,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

extension String {
    // The text cut to at most `limit` Unicode scalars, as the server counts, without splitting a
    // character. The app's own copy is in `TextLimit.swift`.
    nonisolated func cutToServerLength(_ limit: Int) -> String {
        guard unicodeScalars.count > limit else { return self }
        var count = 0
        var end = startIndex
        for character in self {
            let size = character.unicodeScalars.count
            if count + size > limit { break }
            count += size
            end = index(after: end)
        }
        return String(self[..<end])
    }
}
