import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// Where a new attachment comes from, as the add menu asks for it. The pickers that answer are
// shown by `AttachmentPickers`, on a view that stays while the menu closes.
enum AttachmentSource: Hashable {
    case photos
    case camera
    case file
}

// One menu to add an attachment to an item or a note: the photo library, the camera where the
// device has one, a file, and the clipboard while it holds a picture.
struct AttachmentAddMenu<MenuLabel: View>: View {
    @Environment(Store.self) private var store
    // Missing while there is nothing to add to. The menu is then off.
    let holder: AttachmentHolder?
    @Binding var request: AttachmentSource?
    @Binding var failure: String?
    @ViewBuilder let label: () -> MenuLabel

    @State private var canPaste = false

    var body: some View {
        Menu {
            Button("Photo Library", systemImage: "photo.on.rectangle") { request = .photos }
            #if os(iOS)
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Take Photo", systemImage: "camera") { request = .camera }
            }
            #endif
            Button("Choose File", systemImage: "folder") { request = .file }
            if canPaste {
                Button("Paste", systemImage: "doc.on.clipboard") {
                    guard let holder else { return }
                    Task { failure = await AttachmentAdding.image(Clipboard.image(), to: holder, in: store) }
                }
            }
        } label: {
            label()
        }
        .disabled(holder == nil)
        .onAppear { canPaste = Clipboard.hasImage }
        .onReceive(NotificationCenter.default.publisher(for: Clipboard.changed)) { _ in
            canPaste = Clipboard.hasImage
        }
    }
}

// The photo picker, the file importer and the camera that the add menu asks for. A picture is
// scaled and loses its EXIF data before it is sent; a chosen file is kept byte for byte.
struct AttachmentPickers: ViewModifier {
    @Environment(Store.self) private var store
    // Missing while there is nothing to add to. A request then shows nothing.
    let holder: AttachmentHolder?
    let room: Int
    @Binding var request: AttachmentSource?
    @Binding var failure: String?

    @State private var picked: [PhotosPickerItem] = []

    func body(content: Content) -> some View {
        content
            .photosPicker(
                isPresented: isRequested(.photos),
                selection: $picked,
                maxSelectionCount: max(room, 1),
                matching: .images,
            )
            .onChange(of: picked) { _, chosen in
                // The holder as it was when the picker opened.
                guard !chosen.isEmpty, let holder else { return }
                picked = []
                Task {
                    for photo in chosen {
                        failure = await AttachmentAdding.image(
                            try? photo.loadTransferable(type: Data.self), to: holder, in: store,
                        )
                    }
                }
            }
            .fileImporter(
                isPresented: isRequested(.file),
                allowedContentTypes: [.item],
                allowsMultipleSelection: true,
            ) { result in
                guard case .success(let chosen) = result, let holder else { return }
                Task { failure = await AttachmentAdding.files(Array(chosen.prefix(room)), to: holder, in: store) }
            }
            #if os(iOS)
            .fullScreenCover(isPresented: isRequested(.camera)) {
                if let holder {
                    CameraView { data in
                        Task { failure = await AttachmentAdding.image(data, to: holder, in: store) }
                    }
                    .ignoresSafeArea()
                }
            }
            #endif
    }

    private func isRequested(_ source: AttachmentSource) -> Binding<Bool> {
        Binding {
            request == source && holder != nil && room > 0
        } set: { isShown in
            if !isShown, request == source { request = nil }
        }
    }
}

// Adds what a picker, the camera or the clipboard handed over. Each answers with what went wrong,
// to be said next to the attachments, or nil.
enum AttachmentAdding {
    static func image(_ data: Data?, to holder: AttachmentHolder, in store: Store) async -> String? {
        guard let data else { return "That is not a picture Pendenz can read." }
        return await store.addImage(data, to: holder)
    }

    static func files(_ chosen: [URL], to holder: AttachmentHolder, in store: Store) async -> String? {
        var problems: [String] = []
        for url in chosen {
            if let problem = await store.addFile(from: url, to: holder) { problems.append(problem) }
        }
        return problems.isEmpty ? nil : problems.joined(separator: "\n")
    }
}
