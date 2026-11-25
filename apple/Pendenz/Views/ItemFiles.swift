import SwiftUI
import UniformTypeIdentifiers

// One file in the list. It is fetched when it is opened or shared, not before: a file can be
// large, and most are never opened on most devices.
struct ItemFileRow: View {
    @Environment(Store.self) private var store
    let file: ShownFile
    let holder: AttachmentHolder
    @Binding var failure: String?
    let onOpen: (URL) -> Void

    @State private var isLoading = false
    @State private var shared: URL?
    @State private var isAskingToRemove = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: Self.symbol(for: file.mime))
                    .frame(width: 24)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if isLoading {
                    ProgressView()
                } else if file.isWaiting {
                    // Not on the server yet. Said by the label too, not by the mark alone.
                    Image(systemName: "arrow.up.circle")
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
        // A file that is on this device already is shared straight from the menu.
        .task(id: file.id) {
            if shared == nil, let url = store.localFile(file) { shared = store.namedFile(url, file.name) }
        }
        .contextMenu {
            if let shared {
                ShareLink(item: shared)
            } else {
                // Not on this device yet. The file is fetched and opened in the preview, whose
                // share button sends it on, so one choice here leads to the share.
                Button("Share", systemImage: "square.and.arrow.up", action: open)
            }
            Button("Remove", systemImage: "trash", role: .destructive) { isAskingToRemove = true }
        }
        // A removed file does not come back, so this asks.
        .alert("Remove “\(file.name)”?", isPresented: $isAskingToRemove) {
            Button("Remove", role: .destructive) { store.removeFile(file, from: holder) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It is removed from the \(holder.noun) on every device.")
        }
    }

    private var size: String {
        ByteCountFormatter.string(fromByteCount: Int64(file.bytes), countStyle: .file)
    }

    private var detail: String {
        file.isWaiting ? "\(size), not sent yet" : size
    }

    private var accessibilityText: String {
        "\(file.name), \(detail)"
    }

    private func open() {
        guard !isLoading else { return }
        Task {
            if let url = await load() { onOpen(url) }
        }
    }

    private func load() async -> URL? {
        isLoading = true
        defer { isLoading = false }
        guard let url = await store.file(file, of: holder) else {
            failure = "“\(file.name)” could not be loaded. Try again when the server can be reached."
            return nil
        }
        failure = nil
        let named = store.namedFile(url, file.name)
        shared = named
        return named
    }

    // A symbol for the kind of file, from its type.
    private static func symbol(for mime: String) -> String {
        guard let type = UTType(mimeType: mime) else { return "doc" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return "film" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .spreadsheet) { return "tablecells" }
        if type.conforms(to: .presentation) { return "rectangle.on.rectangle" }
        if type.conforms(to: .text) { return "doc.text" }
        return "doc"
    }
}

// Lets pictures and files be dropped onto an item's detail or a note from another app or window.
// A picture is scaled and sent as a photo, anything else is kept byte for byte.
struct ItemAttachmentDrop: ViewModifier {
    @Environment(Store.self) private var store
    let holder: AttachmentHolder

    func body(content: Content) -> some View {
        content.onDrop(of: [.image, .data, .package], isTargeted: nil) { providers in
            let pictures = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
            let files = providers.filter { provider in
                !pictures.contains(provider) && ItemFileDrop.accepts(provider)
            }
            for provider in pictures {
                _ = provider.loadDataRepresentation(for: .image) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in
                        if let problem = await store.addImage(data, to: holder) { store.rejection = problem }
                    }
                }
            }
            for provider in files {
                ItemFileDrop.add(provider, to: holder, in: store)
            }
            return !pictures.isEmpty || !files.isEmpty
        }
    }
}

// A file dropped onto an item's detail or a note, which is not a picture. The system lends the dropped
// file only while it is handed over, so it is copied aside at once and added from there.
private enum ItemFileDrop {
    // Whether a dropped thing is a file to add, and not text or a link dropped onto the screen.
    static func accepts(_ provider: NSItemProvider) -> Bool {
        provider.suggestedName != nil && dataType(of: provider) != nil
    }

    static func add(_ provider: NSItemProvider, to holder: AttachmentHolder, in store: Store) {
        guard let type = dataType(of: provider) else { return }
        let name = provider.suggestedName
        _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, _ in
            guard let url else { return }
            let folder = FileManager.default.temporaryDirectory
                .appending(path: "DroppedFiles/\(UUID().uuidString)", directoryHint: .isDirectory)
            let staged = folder.appending(path: AttachmentFiles.basename(name.map { name in
                // The name the provider gives may lack the extension that the copy carries.
                (name as NSString).pathExtension.isEmpty && !url.pathExtension.isEmpty
                    ? "\(name).\(url.pathExtension)" : name
            } ?? url.lastPathComponent))
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: staged)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                return
            }
            Task { @MainActor in
                if let problem = await store.addFile(from: staged, to: holder) { store.rejection = problem }
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }

    private static func dataType(of provider: NSItemProvider) -> UTType? {
        provider.registeredContentTypes.first { $0.conforms(to: .data) || $0.conforms(to: .package) }
    }
}
