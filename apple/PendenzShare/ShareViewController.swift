import SwiftUI
import UIKit

// The sheet that another app's share menu opens. It reads what was shared, lets the title be
// changed, and leaves a drop in the app group for the app to queue. It holds no token and makes
// no request.
final class ShareViewController: UIViewController {
    private let share = Share()

    override func viewDidLoad() {
        super.viewDidLoad()
        let sheet = UIHostingController(rootView: ShareView(
            share: share,
            onCancel: { [weak self] in self?.cancel() },
            onAdd: { [weak self] in self?.add() },
        ))
        addChild(sheet)
        sheet.view.frame = view.bounds
        sheet.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(sheet.view)
        sheet.didMove(toParent: self)

        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        Task { await share.load(items) }
    }

    private func add() {
        guard share.save() else { return }
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func cancel() {
        share.discard()
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }
}
