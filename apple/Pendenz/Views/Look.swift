import SwiftUI

// The look of the lists in the sidebar layout: rows without lines between them and quiet section
// titles. On the Mac also a rounded selection inset from the edges and a soft top edge. The
// iPhone layout, also on an iPad in a narrow window, keeps the plain list with its lines.
extension EnvironmentValues {
    // Set by `SidebarShell` on its detail column, never by `TabShell`.
    @Entry var usesSidebarLook = false
}

extension View {
    func sidebarListLook() -> some View {
        #if os(macOS)
        listStyle(.inset)
            .alternatingRowBackgrounds(.disabled)
            .scrollEdgeEffectStyle(.soft, for: .top)
        #else
        listStyle(.plain)
        #endif
    }

    // For the rows and sections inside such a list.
    func sidebarListRows() -> some View {
        modifier(SidebarListRows())
    }
}

private struct SidebarListRows: ViewModifier {
    @Environment(\.usesSidebarLook) private var usesSidebarLook

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .listRowSeparator(.hidden)
            .listSectionSeparator(.hidden)
        #else
        content
            .listRowSeparator(usesSidebarLook ? .hidden : .automatic)
            .listSectionSeparator(usesSidebarLook ? .hidden : .automatic)
        #endif
    }
}

// A section of such a list. On the Mac its title is the first row, not a header: the list pins
// the header of the top section and draws a hard line under it, which no setting takes away.
// The title then scrolls with its rows, as the rest of the window does.
// On the iPad the header stays a header: iOS draws no line under a pinned one.
struct ListSection<Content: View>: View {
    #if os(iOS)
    @Environment(\.usesSidebarLook) private var usesSidebarLook
    #endif
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
                if usesSidebarLook {
                    // The header is gray already; a second gray would fall below the contrast
                    // that text needs.
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                } else {
                    Text(title)
                }
            }
        }
        #endif
    }
}

// Room between the last control of a list and the edge of the item details, which no bar behind
// the toolbar marks on the Mac. Last in the toolbar of each view in the detail column: the
// items of a view come after those of the views around it, so only there is it last.
struct DetailsEdge: ToolbarContent {
    @Environment(Navigation.self) private var navigation

    var body: some ToolbarContent {
        #if os(macOS)
        if navigation.itemID != nil {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        #endif
    }
}
