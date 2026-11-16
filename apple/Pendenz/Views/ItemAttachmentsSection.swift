import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

// What is attached to an item, in one place: its pictures as a row of thumbnails, then its files,
// then one menu to add either. A photo from the library or the camera is scaled and loses its
// EXIF data before it is sent; a chosen file is kept byte for byte, whatever its kind. A tap opens
// an attachment in the preview, a long press or a right click offers to share or remove it.
struct ItemAttachmentsSection: View {
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
        let files = store.files(of: item)
        let imageRoom = ImageFiles.perItem - images.count
        let fileRoom = AttachmentFiles.perItem - files.count
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
            }
            ForEach(files) { file in
                ItemFileRow(file: file, itemID: item.id, failure: $failure) { preview = $0 }
            }
            if imageRoom > 0 || fileRoom > 0 {
                addMenu(imageRoom: imageRoom, fileRoom: fileRoom)
            }
        } header: {
            // The preview hangs from the header, the one view of the section that is always
            // there, so a single preview serves every picture and file.
            Text("Attachments")
                .quickLookPreview($preview)
        } footer: {
            if let failure {
                Label(failure, systemImage: "exclamationmark.circle")
            }
        }
    }

    private func addMenu(imageRoom: Int, fileRoom: Int) -> some View {
        Menu {
            if imageRoom > 0 {
                Button("Photo Library", systemImage: "photo.on.rectangle") { isPickingPhotos = true }
                #if os(iOS)
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button("Take Photo", systemImage: "camera") { isTakingPhoto = true }
                }
                #endif
            }
            if fileRoom > 0 {
                Button("Choose File", systemImage: "folder") { isPickingFile = true }
            }
            if imageRoom > 0, canPaste {
                Button("Paste", systemImage: "doc.on.clipboard") {
                    Task { await addImage(Clipboard.image()) }
                }
            }
        } label: {
            Label("Add Attachment", systemImage: "plus")
        }
        .onAppear { canPaste = Clipboard.hasImage }
        .onReceive(NotificationCenter.default.publisher(for: Clipboard.changed)) { _ in
            canPaste = Clipboard.hasImage
        }
        .photosPicker(
            isPresented: $isPickingPhotos,
            selection: $picked,
            maxSelectionCount: max(imageRoom, 1),
            matching: .images,
        )
        .onChange(of: picked) { _, chosen in
            guard !chosen.isEmpty else { return }
            picked = []
            Task {
                for photo in chosen {
                    await addImage(try? photo.loadTransferable(type: Data.self))
                }
            }
        }
        .fileImporter(
            isPresented: $isPickingFile,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true,
        ) { result in
            guard case .success(let chosen) = result else { return }
            addFiles(Array(chosen.prefix(fileRoom)))
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $isTakingPhoto) {
            CameraView { data in
                Task { await addImage(data) }
            }
            .ignoresSafeArea()
        }
        #endif
    }

    private func addImage(_ data: Data?) async {
        if let data, await store.addImage(data, to: item.id) {
            failure = nil
        } else if store.rejection == nil {
            failure = "That is not a picture Pendenz can read."
        }
    }

    private func addFiles(_ chosen: [URL]) {
        Task {
            var problems: [String] = []
            for url in chosen {
                if let problem = await store.addFile(from: url, to: item.id) { problems.append(problem) }
            }
            failure = problems.isEmpty ? nil : problems.joined(separator: "\n")
        }
    }
}
