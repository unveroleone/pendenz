import SwiftUI
import UniformTypeIdentifiers

// One picture in the row. It shows a spinner until its file is here, which for a picture the
// server holds can take a request.
struct ItemImageTile: View {
    @Environment(Store.self) private var store
    @Environment(\.displayScale) private var displayScale
    let image: ShownFile
    let itemID: Int
    let label: String
    let onOpen: (URL) -> Void

    @State private var picture: CGImage?
    @State private var file: URL?
    @State private var hasFailed = false
    @State private var attempts = 0
    @State private var isAskingToRemove = false

    private static let side: CGFloat = 76

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
                if image.isWaiting {
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
            Button("Remove", role: .destructive) { store.removeFile(image, from: itemID) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It is removed from the item on every device.")
        }
        .task(id: attempts) { await load() }
    }

    private var accessibilityText: String {
        if hasFailed { return "\(label), could not be loaded. Try again" }
        return image.isWaiting ? "\(label), not sent yet" : label
    }

    private func load() async {
        hasFailed = false
        guard let source = await store.file(image, of: itemID) else {
            hasFailed = true
            return
        }
        // Three times the points, so the thumbnail stays sharp on every display.
        picture = await Pictures.thumbnail(of: source, side: Int(Self.side * 3))
        hasFailed = picture == nil
        // Under its own name, which the preview and a share show and tell the type by.
        file = store.namedFile(source, image.name)
    }
}

// Whether the clipboard holds a picture, and its bytes. Text is copied here too.
enum Clipboard {
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

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    #else
    static let changed = UIPasteboard.changedNotification

    static var hasImage: Bool {
        UIPasteboard.general.hasImages
    }

    static func image() -> Data? {
        UIPasteboard.general.image?.pngData()
    }

    static func copy(_ text: String) {
        UIPasteboard.general.string = text
    }
    #endif
}

#if os(iOS)
// The system camera, for one photo.
struct CameraView: UIViewControllerRepresentable {
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
