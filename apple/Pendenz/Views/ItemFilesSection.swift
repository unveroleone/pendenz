import QuickLook
import SwiftUI
import UniformTypeIdentifiers

// The files of an item in its detail: one row per file and a way to add more. A tap opens a
// file in the preview, a long press or a right click offers to share or remove it.
struct ItemFilesSection: View {
    @Environment(Store.self) private var store
    let item: Item

    @State private var isPicking = false
    @State private var preview: URL?
    @State private var failure: String?

    var body: some View {
        let files = store.files(of: item)
        Section {
            ForEach(files) { file in
                ItemFileRow(file: file, itemID: item.id, failure: $failure) { preview = $0 }
            }
            if files.count < AttachmentFiles.perItem {
                Button("Add File", systemImage: "plus") { isPicking = true }
                    // In the black or white of the text, not in a tint the form may set.
                    .formAction(.primary)
                    .fileImporter(
                        isPresented: $isPicking,
                        allowedContentTypes: [.item],
                        allowsMultipleSelection: true,
                    ) { result in
                        guard case .success(let picked) = result else { return }
                        add(Array(picked.prefix(AttachmentFiles.perItem - files.count)))
                    }
            }
        } header: {
            // The preview hangs from the header, the one view of the section that is always
            // there, so a single preview serves every row.
            Text("Files")
                .quickLookPreview($preview)
        } footer: {
            if let failure {
                Label(failure, systemImage: "exclamationmark.circle")
            }
        }
    }

    private func add(_ picked: [URL]) {
        Task {
            var problems: [String] = []
            for url in picked {
                if let problem = await store.addFile(from: url, to: item.id) { problems.append(problem) }
            }
            failure = problems.isEmpty ? nil : problems.joined(separator: "\n")
        }
    }
}

// One file in the list. It is fetched when it is opened or shared, not before: a file can be
// large, and most are never opened on most devices.
private struct ItemFileRow: View {
    @Environment(Store.self) private var store
    let file: ShownFile
    let itemID: Int
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
        .contextMenu {
            if let shared {
                ShareLink(item: shared)
            } else {
                Button("Share", systemImage: "square.and.arrow.up") { Task { await prepareShare() } }
            }
            Button("Remove", systemImage: "trash", role: .destructive) { isAskingToRemove = true }
        }
        // A removed file does not come back, so this asks.
        .alert("Remove “\(file.name)”?", isPresented: $isAskingToRemove) {
            Button("Remove", role: .destructive) { store.removeFile(file, from: itemID) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It is removed from the item on every device.")
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

    // The share sheet needs the file first. Once it is here, the menu offers it directly.
    private func prepareShare() async {
        shared = await load()
    }

    private func load() async -> URL? {
        isLoading = true
        defer { isLoading = false }
        guard let url = await store.file(file, of: itemID) else {
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

// A file dropped onto an item's detail from another app or window, which is not a picture:
// pictures become images. The system lends the dropped file only while it is handed over, so it
// is copied aside at once and added from there.
enum ItemFileDrop {
    // Whether a dropped thing is a file to add, and not text or a link dropped onto the detail.
    static func accepts(_ provider: NSItemProvider) -> Bool {
        provider.suggestedName != nil && dataType(of: provider) != nil
    }

    static func add(_ provider: NSItemProvider, to itemID: Int, in store: Store) {
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
                if let problem = await store.addFile(from: staged, to: itemID) { store.rejection = problem }
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }

    private static func dataType(of provider: NSItemProvider) -> UTType? {
        provider.registeredContentTypes.first { $0.conforms(to: .data) || $0.conforms(to: .package) }
    }
}
