import SwiftUI

// On top of the lists while the server is older than this build needs, because until it is
// updated some changes wait. Settings says the same under the server's address.
struct OutdatedServerSection: View {
    @Environment(Store.self) private var store

    var body: some View {
        if let notice = store.outdatedServerNotice {
            Section {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
            }
        }
    }
}
