import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// The image files on this device. Two kinds: JPEGs that wait to be sent, which exist only here
// and so lie next to the local store, and copies of images the server holds, which can be
// fetched again and so lie in the caches folder.
nonisolated struct ImageFiles: Sendable {
    // The long side of an image as it is sent.
    static let sentSize = 2048
    static let perItem = 20

    private let waiting: URL
    private let cache: URL

    init() {
        let manager = FileManager.default
        let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let caches = manager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        waiting = support.appending(path: "WaitingImages", directoryHint: .isDirectory)
        cache = caches.appending(path: "Images", directoryHint: .isDirectory)
        for folder in [waiting, cache] {
            try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    // MARK: Waiting

    func waitingFile(_ image: PendingImage) -> URL {
        waiting.appending(path: "\(image.id).jpg")
    }

    // Written in one step, so a file that exists is complete.
    func keep(_ data: Data, for image: PendingImage) -> Bool {
        (try? data.write(to: waitingFile(image), options: .atomic)) != nil
    }

    func data(of image: PendingImage) -> Data? {
        try? Data(contentsOf: waitingFile(image))
    }

    func discard(_ image: PendingImage) {
        try? FileManager.default.removeItem(at: waitingFile(image))
        try? FileManager.default.removeItem(at: Self.links.appending(path: image.id))
    }

    // Removes every waiting file that no change in the outbox names: left by a crash between
    // the file and its entry, or by a store that was emptied for another server.
    func discardWaiting(except kept: [PendingImage]) {
        let names = Set(kept.map { "\($0.id).jpg" })
        let files = (try? FileManager.default.contentsOfDirectory(atPath: waiting.path(percentEncoded: false))) ?? []
        for file in files where !names.contains(file) {
            try? FileManager.default.removeItem(at: waiting.appending(path: file))
        }
        // The named links of an earlier launch. They are made again when an image is shown.
        try? FileManager.default.removeItem(at: Self.links)
    }

    // MARK: Copies of the server's images

    // The extension matters: the full view tells the type by it.
    private func copy(_ image: ItemImage) -> URL {
        cache.appending(path: "\(image.sha256).\(image.mime == "image/png" ? "png" : "jpg")")
    }

    func file(of image: ItemImage) -> URL? {
        let url = copy(image)
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    // The item no longer has this image, so its copy goes.
    func forget(_ image: ItemImage) {
        let url = copy(image)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default
            .removeItem(at: Self.links.appending(path: url.deletingPathExtension().lastPathComponent))
    }

    // Keeps the bytes only when they are the image the server listed.
    func keep(_ data: Data, as image: ItemImage) -> URL? {
        guard Self.hash(data) == image.sha256 else { return nil }
        let url = copy(image)
        return (try? data.write(to: url, options: .atomic)) != nil ? url : nil
    }

    // The same file under a name a person can read, for the full view and for sharing, which
    // both show the file's name. A link, so it takes no room of its own, but it keeps the bytes
    // alive: it has to go when the file it names goes.
    private static let links = FileManager.default.temporaryDirectory.appending(
        path: "Images",
        directoryHint: .isDirectory,
    )

    func named(_ file: URL, _ name: String) -> URL {
        let folder = Self.links.appending(
            path: file.deletingPathExtension().lastPathComponent,
            directoryHint: .isDirectory,
        )
        let link = folder.appending(path: "\(name).\(file.pathExtension)")
        if FileManager.default.fileExists(atPath: link.path(percentEncoded: false)) { return link }
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if (try? FileManager.default.linkItem(at: file, to: link)) != nil { return link }
        return (try? FileManager.default.copyItem(at: file, to: link)) != nil ? link : file
    }

    func emptyCache() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: cache.path(percentEncoded: false))) ?? []
        for file in files {
            try? FileManager.default.removeItem(at: cache.appending(path: file))
        }
        try? FileManager.default.removeItem(at: Self.links)
    }

    // Nothing of the server's data stays on the device.
    func erase() {
        emptyCache()
        discardWaiting(except: [])
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Pixels

    // The image as it is sent: at most 2048 pixels on its long side, upright, as a JPEG. The
    // copy is drawn anew, so nothing of the original's EXIF data, such as the place it was
    // taken at, travels with it.
    @concurrent
    static func scaled(_ data: Data) async -> (jpeg: Data, width: Int, height: Int)? {
        guard let picture = downsampled(CGImageSourceCreateWithData(data as CFData, nil), to: sentSize) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else {
            return nil
        }
        let options = [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary
        CGImageDestinationAddImage(destination, picture, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (output as Data, picture.width, picture.height)
    }

    // A small picture of a file for a thumbnail, without reading the whole image into memory.
    @concurrent
    static func thumbnail(of file: URL, side: Int) async -> CGImage? {
        downsampled(CGImageSourceCreateWithURL(file as CFURL, nil), to: side)
    }

    private static func downsampled(_ source: CGImageSource?, to side: Int) -> CGImage? {
        guard let source else { return nil }
        let options = [
            // From the image itself, never from a preview embedded in the file.
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Turned upright, as the orientation in the file says.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}
