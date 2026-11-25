#if os(macOS)
import Carbon.HIToolbox

// The keyboard shortcuts that open quick capture from any app: a few fixed ones, not a recorder.
enum CaptureShortcut: String, CaseIterable, Identifiable {
    case off
    case controlOptionP
    case controlOptionN
    case controlOptionSpace

    var id: Self { self }

    var title: String {
        switch self {
        case .off: "Off"
        case .controlOptionP: "⌃⌥P"
        case .controlOptionN: "⌃⌥N"
        case .controlOptionSpace: "⌃⌥Space"
        }
    }

    fileprivate var keyCode: UInt32? {
        switch self {
        case .off: nil
        case .controlOptionP: UInt32(kVK_ANSI_P)
        case .controlOptionN: UInt32(kVK_ANSI_N)
        case .controlOptionSpace: UInt32(kVK_Space)
        }
    }

    fileprivate var modifiers: UInt32 {
        UInt32(controlKey | optionKey)
    }
}

// One global shortcut through the Carbon event manager. It needs no permission and works in the
// App Sandbox. A global event monitor of AppKit would need Accessibility and could not keep the
// key from the app in front.
enum HotKey {
    enum Failure: Equatable {
        // Another app holds the shortcut for itself.
        case taken
        case failed(OSStatus)
    }

    // Called on the main thread when the shortcut is pressed.
    static var pressed: () -> Void = {}

    private static var registered: EventHotKeyRef?
    private static var handler: EventHandlerRef?

    // Registers the shortcut in place of the one before. When that fails, none is left: the
    // setting then says so, rather than a shortcut that is not the chosen one working on.
    static func register(_ shortcut: CaptureShortcut) -> Failure? {
        unregister()
        guard let keyCode = shortcut.keyCode else { return nil }
        if let failure = installHandler() { return failure }
        // Exclusive, because Carbon otherwise shares a shortcut, and the key would then also
        // reach another app that has it.
        let id = EventHotKeyID(signature: OSType(0x5044_4E5A), id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode, shortcut.modifiers, id, GetEventDispatcherTarget(), OptionBits(kEventHotKeyExclusive), &ref,
        )
        switch status {
        case noErr:
            registered = ref
            return nil
        case OSStatus(eventHotKeyExistsErr):
            return .taken
        default:
            return .failed(status)
        }
    }

    static func unregister() {
        if let registered { UnregisterEventHotKey(registered) }
        registered = nil
    }

    private static func installHandler() -> Failure? {
        guard handler == nil else { return nil }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetEventDispatcherTarget(), hotKeyPressed, 1, &type, nil, &handler)
        return status == noErr ? nil : .failed(status)
    }
}

// The Carbon event manager calls this on the main thread. There is one shortcut, so the event
// needs no further look.
private nonisolated func hotKeyPressed(_: EventHandlerCallRef?, _: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus {
    MainActor.assumeIsolated { HotKey.pressed() }
    return noErr
}
#endif
