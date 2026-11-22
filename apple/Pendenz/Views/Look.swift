import SwiftUI

// The look of the lists on the Mac: rows that float on the window without lines between them,
// a rounded selection inset from the edges, and quiet section headers. The iPhone and the iPad
// keep the plain list.
extension View {
    func macListLook() -> some View {
        #if os(macOS)
        listStyle(.inset)
            .alternatingRowBackgrounds(.disabled)
            .scrollEdgeEffectStyle(.soft, for: .top)
        #else
        listStyle(.plain)
        #endif
    }

    // For the rows and sections inside such a list.
    func macListRows() -> some View {
        #if os(macOS)
        listRowSeparator(.hidden)
            .listSectionSeparator(.hidden)
        #else
        self
        #endif
    }
}

// A section of such a list. On the Mac its title is the first row, not a header: the list pins
// the header of the top section and draws a hard line under it, which no setting takes away.
// The title then scrolls with its rows, as the rest of the window does.
struct ListSection<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    init(_ title: String?, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        #if os(macOS)
        Section {
            if let title {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                    .accessibilityAddTraits(.isHeader)
                    .selectionDisabled()
                    .moveDisabled(true)
            }
            content
        }
        #else
        Section {
            content
        } header: {
            if let title {
                Text(title)
            }
        }
        #endif
    }
}
