import Foundation

// What a file belongs to: an item or a note. Both keep their files the same way, and the server
// looks a file up together with its holder. An item and a note can have the same number, a
// local one below zero too, so a file is never found by the number alone.
nonisolated enum AttachmentHolder: Hashable, Sendable {
    case item(Int)
    case note(Int)

    var id: Int {
        switch self {
        case .item(let id), .note(let id): id
        }
    }

    // The holder's path in the API.
    var path: String {
        switch self {
        case .item(let id): "api/items/\(id)"
        case .note(let id): "api/notes/\(id)"
        }
    }

    // How the screens name it, in "It is removed from the item on every device."
    var noun: String {
        switch self {
        case .item: "item"
        case .note: "note"
        }
    }

    func with(id: Int) -> Self {
        switch self {
        case .item: .item(id)
        case .note: .note(id)
        }
    }
}

extension PendingWrite {
    // The waiting upload of a file to an item or a note.
    static func addFile(_ file: PendingFile, to holder: AttachmentHolder) -> Self {
        switch holder {
        case .item(let id): .addFile(itemID: id, file: file)
        case .note(let id): .addNoteFile(noteID: id, file: file)
        }
    }

    static func removeFile(_ fileID: Int, from holder: AttachmentHolder) -> Self {
        switch holder {
        case .item(let id): .removeFile(itemID: id, fileID: fileID)
        case .note(let id): .removeNoteFile(noteID: id, fileID: fileID)
        }
    }

    // An upload with what it goes to, for the code that treats items and notes alike.
    var upload: (holder: AttachmentHolder, file: PendingFile)? {
        switch self {
        case .addFile(let id, let file): (.item(id), file)
        case .addNoteFile(let id, let file): (.note(id), file)
        default: nil
        }
    }

    // A removal with what it is removed from.
    var removal: (holder: AttachmentHolder, fileID: Int)? {
        switch self {
        case .removeFile(let id, let fileID): (.item(id), fileID)
        case .removeNoteFile(let id, let fileID): (.note(id), fileID)
        default: nil
        }
    }
}
