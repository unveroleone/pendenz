import CryptoKit
import Foundation
import UniformTypeIdentifiers

// The files of items on this device, as `ImageFiles` keeps the images. Two kinds: files that wait
// to be sent, which exist only here and so lie next to the local store, and copies of files the
// server holds, which can be fetched again and so lie in the caches folder. A file can be large,
// so nothing here reads one whole into memory.
nonisolated struct AttachmentFiles: Sendable {
    static let perItem = 20
    // What a megabyte means for the limit: the server and the system's sizes count in thousands.
    static let megabyte = 1_000_000

    private let waiting: URL
    private let cache: URL

    init() {
        let manager = FileManager.default
        let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let caches = manager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        waiting = support.appending(path: "WaitingFiles", directoryHint: .isDirectory)
        cache = caches.appending(path: "Files", directoryHint: .isDirectory)
        for folder in [waiting, cache] {
            try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    // MARK: Waiting

    func waitingFile(_ file: PendingFile) -> URL {
        waiting.appending(path: file.id)
    }

    // Copies a picked file into the waiting folder, under a temporary name first, so a file
    // with the final name is always complete. The copy is made by the file system, without
    // reading the bytes into memory. False when it could not be made.
    @concurrent
    static func copy(_ source: URL, to destination: URL) async -> Bool {
        let manager = FileManager.default
        let part = destination.appendingPathExtension("part")
        try? manager.removeItem(at: part)
        do {
            try manager.copyItem(at: source, to: part)
            try? manager.removeItem(at: destination)
            try manager.moveItem(at: part, to: destination)
            return true
        } catch {
            try? manager.removeItem(at: part)
            return false
        }
    }

    func discard(_ file: PendingFile) {
        try? FileManager.default.removeItem(at: waitingFile(file))
        try? FileManager.default.removeItem(at: Self.links.appending(path: file.id))
    }

    // Removes every waiting file that no change in the outbox names: left by a crash between
    // the file and its entry, or by a store that was emptied for another server.
    func discardWaiting(except kept: [PendingFile]) {
        let names = Set(kept.map(\.id))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: waiting.path(percentEncoded: false))) ?? []
        for file in files where !names.contains(file) {
            try? FileManager.default.removeItem(at: waiting.appending(path: file))
        }
        // The named links of an earlier launch. They are made again when a file is opened.
        try? FileManager.default.removeItem(at: Self.links)
    }

    // MARK: Copies of the server's files

    private func copy(_ file: ItemFile) -> URL {
        cache.appending(path: file.sha256)
    }

    func file(of file: ItemFile) -> URL? {
        let url = copy(file)
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    // The item no longer has this file, so its copy goes.
    func forget(_ file: ItemFile) {
        try? FileManager.default.removeItem(at: copy(file))
        try? FileManager.default.removeItem(at: Self.links.appending(path: file.sha256))
    }

    // Keeps a downloaded file only when it is the one the server listed. The download is moved,
    // not copied.
    @concurrent
    func keep(download: URL, as file: ItemFile) async -> URL? {
        guard await Self.hash(of: download) == file.sha256 else {
            try? FileManager.default.removeItem(at: download)
            return nil
        }
        let url = copy(file)
        try? FileManager.default.removeItem(at: url)
        do {
            try FileManager.default.moveItem(at: download, to: url)
            return url
        } catch {
            try? FileManager.default.removeItem(at: download)
            return nil
        }
    }

    // A file this device sent and the server now holds: its waiting file becomes the copy, so it
    // is not fetched again right after it was sent. A second link to the same bytes, which takes
    // no room; the waiting name goes once its outbox entry is gone.
    func adopt(_ pending: PendingFile, as file: ItemFile) {
        let url = copy(file)
        guard !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        if (try? FileManager.default.linkItem(at: waitingFile(pending), to: url)) == nil {
            try? FileManager.default.copyItem(at: waitingFile(pending), to: url)
        }
    }

    // The same file under its own name, for the preview and for sharing, which both show the
    // name and tell the type by its extension. A link, so it takes no room of its own, but it
    // keeps the bytes alive: it has to go when the file it names goes.
    private static let links = FileManager.default.temporaryDirectory.appending(
        path: "Files",
        directoryHint: .isDirectory,
    )

    func named(_ file: URL, _ name: String) -> URL {
        let folder = Self.links.appending(path: file.lastPathComponent, directoryHint: .isDirectory)
        let link = folder.appending(path: Self.basename(name))
        if FileManager.default.fileExists(atPath: link.path(percentEncoded: false)) { return link }
        // The same bytes can be on items under several names. The folder keeps the links made
        // for the others, which a row may still hand to a share.
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

    // MARK: Names and types

    // A name that is one path component and nothing else: the server's rules, applied here too
    // before a name becomes part of a path on this device. At most 255 bytes, the extension kept.
    static func basename(_ name: String) -> String {
        var name = String(name.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar) && scalar != "/" && scalar != "\\" && scalar != ":"
        }).trimmingCharacters(in: .whitespaces)
        if name.isEmpty || name == "." || name == ".." { name = "File" }
        guard name.utf8.count > 255 else { return name }
        let ext = (name as NSString).pathExtension
        let suffix = ext.isEmpty || ext.utf8.count > 16 ? "" : "." + ext
        var stem = suffix.isEmpty ? name : String(name.dropLast(suffix.count))
        while stem.utf8.count + suffix.utf8.count > 255 {
            stem.removeLast()
        }
        return stem + suffix
    }

    // The type a file is sent with, from its name. The server stores what it gets.
    static func mime(forName name: String) -> String {
        UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    // The SHA-256 of a file in lowercase hex, read a megabyte at a time.
    @concurrent
    static func hash(of file: URL) async -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let chunk = try? handle.read(upToCount: megabyte) else { return nil }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
