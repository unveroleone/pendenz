#if os(macOS)
import AppKit
import SwiftUI

// Quick capture on the Mac: an item in the menu bar and a global shortcut, both opening a small
// panel with quick add for the inbox. It lives as long as the app, apart from any window, and
// writes through the store's outbox like quick add in a window.
@Observable
final class MenuBarCapture: NSObject {
    static let shared = MenuBarCapture()

    var showsInMenuBar: Bool {
        didSet {
            UserDefaults.standard.set(showsInMenuBar, forKey: "menuBarCapture")
            placeStatusItem()
        }
    }

    var shortcut: CaptureShortcut {
        didSet {
            UserDefaults.standard.set(shortcut.rawValue, forKey: "captureShortcut")
            registerShortcut()
        }
    }

    // Why the chosen shortcut does not work, for the setting.
    private(set) var shortcutFailure: HotKey.Failure?

    @ObservationIgnored private var session: Session?
    @ObservationIgnored private var statusItem: NSStatusItem?
    @ObservationIgnored private var panel: CapturePanel?
    // When the panel last closed because something else took the keyboard. A click on the menu
    // bar item does that first, and must then not open it again at once.
    @ObservationIgnored private var closedByClickAt: Date?

    override private init() {
        let defaults = UserDefaults.standard
        showsInMenuBar = defaults.object(forKey: "menuBarCapture") as? Bool ?? true
        shortcut = defaults.string(forKey: "captureShortcut").flatMap(CaptureShortcut.init) ?? .controlOptionP
        super.init()
    }

    func start(session: Session) {
        self.session = session
        HotKey.pressed = { [weak self] in self?.toggle() }
        placeStatusItem()
        registerShortcut()
    }

    private func registerShortcut() {
        guard session != nil else { return }
        shortcutFailure = HotKey.register(shortcut)
    }

    private func placeStatusItem() {
        guard session != nil else { return }
        if showsInMenuBar, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            // The app's icon in one color, which the menu bar tints (apple/icon/menubar.swift).
            item.button?.image = NSImage(named: "MenuBarIcon")
            item.button?.image?.accessibilityDescription = "Pendenz"
            item.button?.toolTip = "New Item in Pendenz"
            item.button?.target = self
            item.button?.action = #selector(clicked)
            statusItem = item
        } else if !showsInMenuBar, let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    @objc private func clicked() {
        if let closedByClickAt, Date.now.timeIntervalSince(closedByClickAt) < 0.3 { return }
        toggle()
    }

    func toggle() {
        if panel?.isVisible == true { close() } else { show() }
    }

    func show() {
        guard let session else { return }
        let panel = panel ?? makePanel(session: session)
        self.panel = panel
        panel.setContentSize(panel.contentView?.fittingSize ?? panel.frame.size)
        panel.setFrameTopLeftPoint(topLeft(for: panel.frame.size))
        // Takes the keyboard without making Pendenz the active app, so its windows stay where
        // they are and the app in front gets the keyboard back when the panel closes.
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func makePanel(session: Session) -> CapturePanel {
        let panel = CapturePanel()
        // Also called when the panel closes itself. Then it is no longer visible.
        panel.onResign = { [weak self, weak panel] in
            guard let self, panel?.isVisible == true else { return }
            closedByClickAt = .now
            close()
        }
        panel.onCancel = { [weak self] in self?.close() }
        let view = CaptureView(session: session) { [weak self] in self?.close() }
        panel.contentView = NSHostingView(rootView: view)
        return panel
    }

    // Under the menu bar item, or at the top of the screen with the pointer when there is no
    // item to hang from: switched off, or hidden behind the camera housing.
    private func topLeft(for size: CGSize) -> CGPoint {
        let gap: CGFloat = 6
        if let button = statusItem?.button, let window = button.window, let screen = window.screen,
           screen.frame.intersects(window.frame)
        {
            let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
            let visible = screen.visibleFrame
            let x = min(max(anchor.midX - size.width / 2, visible.minX + gap), visible.maxX - size.width - gap)
            return CGPoint(x: x, y: anchor.minY - gap)
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        return CGPoint(x: visible.midX - size.width / 2, y: visible.maxY - gap)
    }
}

// A panel that takes the keyboard while Pendenz stays in the background, over every Space and
// over apps in full screen.
final class CapturePanel: NSPanel {
    var onResign: () -> Void = {}
    var onCancel: () -> Void = {}

    init() {
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 420, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true,
        )
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
    }

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        onResign()
    }

    // Escape.
    override func cancelOperation(_: Any?) {
        onCancel()
    }
}

// Quick add for the inbox, or a word on pairing first. The field keeps its text when the panel
// closes without adding, and starts empty for another pairing.
private struct CaptureView: View {
    let session: Session
    let added: () -> Void

    var body: some View {
        Group {
            if let store = session.store {
                QuickAddView(place: .inbox, onAdd: added)
                    .environment(store)
                    .id(ObjectIdentifier(store))
            } else {
                Text("Pair this Mac in Pendenz first.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
        }
        .frame(width: 420)
        .background(.regularMaterial, in: .rect(cornerRadius: 14))
    }
}
#endif
