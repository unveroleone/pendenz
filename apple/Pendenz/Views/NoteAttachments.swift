import QuickLook
import SwiftUI

// What is attached to a note, under its text: the pictures as thumbnails, then the files, in one
// row that scrolls sideways. It is there only while the note has attachments or something went
// wrong adding one. A tap opens an attachment in the preview, a long press or a right click
// offers to share or remove it. The editor shows it only while the note's text is on screen, and
// keys it by the note, so nothing of one note is left in it when another opens.
struct NoteAttachments: View {
    @Environment(Store.self) private var store
    let noteID: Int
    @Binding var failure: String?

    @State private var preview: URL?
    private var lock: NoteLock { .shared }

    private static let height: CGFloat = 76

    var body: some View {
        let all = store.files(of: .note(noteID))
        let pictures = all.filter(\.isPicture)
        let files = all.filter { !$0.isPicture }
        if !all.isEmpty || failure != nil {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                if !all.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(Array(pictures.enumerated()), id: \.element.id) { index, picture in
                                ItemImageTile(
                                    image: picture, holder: .note(noteID),
                                    label: "Image \(index + 1) of \(pictures.count)",
                                ) { preview = $0 }
                            }
                            ForEach(files) { file in
                                ItemFileRow(file: file, holder: .note(noteID), failure: $failure) { preview = $0 }
                                    .padding(.horizontal, 12)
                                    .frame(width: 220, height: Self.height)
                                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .scrollIndicators(.hidden)
                    .accessibilityLabel("Attachments")
                }
                if let failure {
                    Label(failure, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                }
            }
            .padding(.bottom, 8)
            // One preview for every picture and file of the note.
            .quickLookPreview($preview)
            // Nothing of a locked note stays on screen once its lock closes.
            .onChange(of: lock.isOpen) { _, isOpen in
                if !isOpen { preview = nil }
            }
        }
    }
}
