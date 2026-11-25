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
        let all = store.files(of: item)
        let pictures = all.filter(\.isPicture)
        let files = all.filter { !$0.isPicture }
        let room = AttachmentFiles.perItem - all.count
        Section {
            if !pictures.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Array(pictures.enumerated()), id: \.element.id) { index, picture in
                            ItemImageTile(
                                image: picture, holder: .item(item.id),
                                label: "Image \(index + 1) of \(pictures.count)",
                            ) { preview = $0 }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
            }
            ForEach(files) { file in
                ItemFileRow(file: file, holder: .item(item.id), failure: $failure) { preview = $0 }
            }
            if room > 0 {
                addMenu(room: room)
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
            maxSelectionCount: room,
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
            addFiles(Array(chosen.prefix(room)))
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
        guard let data else {
            failure = "That is not a picture Pendenz can read."
            return
        }
        failure = await store.addImage(data, to: .item(item.id))
    }

    private func addFiles(_ chosen: [URL]) {
        Task {
            var problems: [String] = []
            for url in chosen {
                if let problem = await store.addFile(from: url, to: .item(item.id)) { problems.append(problem) }
            }
            failure = problems.isEmpty ? nil : problems.joined(separator: "\n")
        }
    }
}
