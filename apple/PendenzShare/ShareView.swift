import SwiftUI

// One item for the inbox: its title, and below it what was shared.
struct ShareView: View {
    let share: Share
    let onCancel: () -> Void
    let onAdd: () -> Void

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Add to Inbox")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add", action: onAdd)
                            .disabled(!share.canAdd)
                            .accessibilityIdentifier("share-add")
                    }
                }
        }
        .tint(.primary)
    }

    @ViewBuilder
    private var content: some View {
        switch share.phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unpaired:
            ContentUnavailableView(
                "Not Paired",
                systemImage: "tray",
                description: Text("Open Pendenz and pair it with your server first."),
            )
        case .empty:
            ContentUnavailableView(
                "Nothing to Add",
                systemImage: "tray",
                description: Text("Pendenz can add links, text and images to the inbox."),
            )
        case .ready, .failed:
            form
        }
    }

    private var form: some View {
        Form {
            Section {
                TextField("Title", text: Bindable(share).title, axis: .vertical)
                    .lineLimit(1 ... 4)
                    .accessibilityLabel("Title")
                    .accessibilityIdentifier("share-title")
            }
            if share.link != nil || share.text != nil || !share.pictures.isEmpty {
                Section {
                    if let link = share.link {
                        Label {
                            Text(link.absoluteString)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "link")
                        }
                    }
                    if let text = share.text, text != share.title {
                        Text(text)
                            .lineLimit(6)
                            .foregroundStyle(.secondary)
                    }
                    if !share.pictures.isEmpty {
                        pictures
                    }
                }
            }
            Section {} footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if share.phase == .failed {
                        Text("The share could not be saved on this device. Try again.")
                            .foregroundStyle(.red)
                    }
                    if let notice = share.notice {
                        Text(notice)
                    }
                    Text("It goes to the inbox the next time Pendenz opens.")
                }
            }
        }
    }

    private var pictures: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(share.pictures) { picture in
                    Group {
                        if let preview = picture.preview {
                            Image(decorative: preview, scale: 1)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 72, height: 72)
                    .background(.quaternary)
                    .clipShape(.rect(cornerRadius: 8))
                }
            }
        }
        .scrollIndicators(.hidden)
        .accessibilityLabel(share.pictures.count == 1 ? "1 image" : "\(share.pictures.count) images")
    }
}
