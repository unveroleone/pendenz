import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

// The images of an item in its detail: a row of thumbnails and the ways to add one. A tap
// opens an image in full, a long press or a right click offers to share or remove it.
struct ItemImagesSection: View {
    @Environment(Store.self) private var store
    let item: Item

    @State private var picked: [PhotosPickerItem] = []
    @State private var isPickingPhotos = false
    @State private var isPickingFile = false
    @State private var isTakingPhoto = false
    @State private var canPaste = false
    @State private var preview: URL?
    @State private var failure: String?

    var body: some View {
        let images = store.images(of: item)
        Section {
            if !images.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                            ItemImageTile(
                                image: image, itemID: item.id, name: "Image \(index + 1)",
                                label: "Image \(index + 1) of \(images.count)",
                            ) { preview = $0 }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
                .quickLookPreview($preview)
            }
            if images.count < ImageFiles.perItem {
                addMenu(room: ImageFiles.perItem - images.count)
            }
        } header: {
            Text("Images")
        } footer: {
            if let failure {
                Label(failure, systemImage: "exclamationmark.circle")
            }
        }
    }

    private func addMenu(room: Int) -> some View {
        Menu {
            Button("Photo Library", systemImage: "photo.on.rectangle") { isPickingPhotos = true }
            #if os(iOS)
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Take Photo", systemImage: "camera") { isTakingPhoto = true }
            }
            #endif
            Button("Choose File", systemImage: "folder") { isPickingFile = true }
            if canPaste {
                Button("Paste", systemImage: "doc.on.clipboard") {
                    Task { await add(Clipboard.image()) }
                }
            }
        } label: {
            Label("Add Image", systemImage: "plus")
                // In the gray of the form's tint the row read as switched off.
                .foregroundStyle(.primary)
        }
        .onAppear { canPaste = Clipboard.hasImage }
        .onReceive(NotificationCenter.default.publisher(for: Clipboard.changed)) { _ in
            canPaste = Clipboard.hasImage
        }
        .photosPicker(isPresented: $isPickingPhotos, selection: $picked, maxSelectionCount: room, matching: .images)
        .onChange(of: picked) { _, chosen in
            guard !chosen.isEmpty else { return }
            picked = []
            Task {
                for photo in chosen {
                    await add(try? photo.loadTransferable(type: Data.self))
                }
            }
        }
        .fileImporter(
            isPresented: $isPickingFile,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true,
        ) { result in
            guard case .success(let files) = result else { return }
            Task {
                for file in files.prefix(room) {
                    // A file chosen outside the app's own folders is only readable in between.
                    let isScoped = file.startAccessingSecurityScopedResource()
                    let data = try? Data(contentsOf: file)
                    if isScoped { file.stopAccessingSecurityScopedResource() }
                    await add(data)
                }
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $isTakingPhoto) {
            CameraView { data in
                Task { await add(data) }
            }
            .ignoresSafeArea()
        }
        #endif
    }

    private func add(_ data: Data?) async {
        if let data, await store.addImage(data, to: item.id) {
            failure = nil
        } else if store.rejection == nil {
            failure = "That is not a picture Pendenz can read."
        }
    }
}

// Lets images be dropped onto an item's detail from another app or window.
struct ItemImageDrop: ViewModifier {
    @Environment(Store.self) private var store
    let itemID: Int

    func body(content: Content) -> some View {
        content.onDrop(of: [.image], isTargeted: nil) { providers in
            let images = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
            for provider in images {
                _ = provider.loadDataRepresentation(for: .image) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in
                        await store.addImage(data, to: itemID)
                    }
                }
            }
            return !images.isEmpty
        }
    }
}

// One image in the row. It shows a spinner until its file is here, which for an image the
// server holds can take a request.
private struct ItemImageTile: View {
    @Environment(Store.self) private var store
    @Environment(\.displayScale) private var displayScale
    let image: ShownImage
    let itemID: Int
    // The name of the file as the full view and a share show it.
    let name: String
    let label: String
    let onOpen: (URL) -> Void

    @State private var picture: CGImage?
    @State private var file: URL?
    @State private var hasFailed = false
    @State private var attempts = 0
    @State private var isAskingToRemove = false

    private static let side: CGFloat = 76

    private var isWaiting: Bool {
        if case .waiting = image { true } else { false }
    }

    var body: some View {
        Button {
            if let file {
                onOpen(file)
            } else if hasFailed {
                attempts += 1
            }
        } label: {
            ZStack {
                Rectangle().fill(.quaternary)
                if let picture {
                    Image(decorative: picture, scale: displayScale)
                        .resizable()
                        .scaledToFill()
                } else if hasFailed {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .frame(width: Self.side, height: Self.side)
            .clipShape(.rect(cornerRadius: 10))
            .overlay(alignment: .bottomTrailing) {
                if isWaiting {
                    // Not on the server yet. Said by the label too, not by the mark alone.
                    Image(systemName: "arrow.up.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                        .padding(4)
                }
            }
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
        .contextMenu {
            if let file {
                ShareLink(item: file)
            }
            Button("Remove", systemImage: "trash", role: .destructive) { isAskingToRemove = true }
        }
        // A removed image does not come back, so this asks.
        .alert("Remove this image?", isPresented: $isAskingToRemove) {
            Button("Remove", role: .destructive) { store.removeImage(image, from: itemID) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It is removed from the item on every device.")
        }
        .task(id: attempts) { await load() }
    }

    private var accessibilityText: String {
        if hasFailed { return "\(label), could not be loaded. Try again" }
        return isWaiting ? "\(label), not sent yet" : label
    }

    private func load() async {
        hasFailed = false
        guard let source = await store.imageFile(image, of: itemID) else {
            hasFailed = true
            return
        }
        // Three times the points, so the thumbnail stays sharp on every display.
        picture = await ImageFiles.thumbnail(of: source, side: Int(Self.side * 3))
        hasFailed = picture == nil
        file = store.namedImageFile(source, name)
    }
}

// Whether the clipboard holds a picture, and its bytes.
private enum Clipboard {
    #if os(macOS)
    // The Mac sends no notice when the clipboard changes; the app coming to the front is the
    // moment something new can be in it.
    static let changed = NSApplication.didBecomeActiveNotification

    static var hasImage: Bool {
        NSPasteboard.general.canReadItem(withDataConformingToTypes: [UTType.image.identifier])
    }

    static func image() -> Data? {
        let board = NSPasteboard.general
        return [NSPasteboard.PasteboardType.png, .tiff].lazy.compactMap { board.data(forType: $0) }.first
    }
    #else
    static let changed = UIPasteboard.changedNotification

    static var hasImage: Bool {
        UIPasteboard.general.hasImages
    }

    static func image() -> Data? {
        UIPasteboard.general.image?.pngData()
    }
    #endif
}

#if os(iOS)
// The system camera, for one photo.
private struct CameraView: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let onPhoto: (Data) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_: UIImagePickerController, context _: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPhoto: onPhoto) { dismiss() }
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onPhoto: (Data) -> Void
        private let onClose: () -> Void

        init(onPhoto: @escaping (Data) -> Void, onClose: @escaping () -> Void) {
            self.onPhoto = onPhoto
            self.onClose = onClose
        }

        func imagePickerController(
            _: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any],
        ) {
            // The store scales it and writes the JPEG that is sent; this one only carries
            // the pixels there.
            if let data = (info[.originalImage] as? UIImage)?.jpegData(compressionQuality: 0.95) {
                onPhoto(data)
            }
            onClose()
        }

        func imagePickerControllerDidCancel(_: UIImagePickerController) {
            onClose()
        }
    }
}
#endif
