import QuickLook
import SwiftUI

// What is attached to an item, in one place: its pictures as a row of thumbnails, then its files,
// then one menu to add either. A photo from the library or the camera is scaled and loses its
// EXIF data before it is sent; a chosen file is kept byte for byte, whatever its kind. A tap opens
// an attachment in the preview, a long press or a right click offers to share or remove it.
struct ItemAttachmentsSection: View {
    @Environment(Store.self) private var store
    let item: Item

    @State private var request: AttachmentSource?
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
        AttachmentAddMenu(holder: .item(item.id), request: $request, failure: $failure) {
            Label("Add Attachment", systemImage: "plus")
        }
        .modifier(AttachmentPickers(holder: .item(item.id), room: room, request: $request, failure: $failure))
    }
}
