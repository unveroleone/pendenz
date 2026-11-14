import CoreTransferable
import UniformTypeIdentifiers

// What travels when a row is dragged: enough to find the item again where it is dropped.
nonisolated struct ItemRef: Codable, Sendable, Transferable {
    let id: Int

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .pendenzItem)
    }
}

extension UTType {
    // Declared in Info.plist. Only Pendenz reads it, so a dragged row is never taken for
    // dropped text and added a second time.
    nonisolated static let pendenzItem = UTType(exportedAs: "com.unveroleone.pendenz.item")
}
