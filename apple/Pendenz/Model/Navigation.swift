import Foundation
import Observation

// What one window has open. The menu commands act on the front window through this.
@Observable
final class Navigation {
    // The list shown on Mac and iPad. The iPhone keeps its own tab.
    var place: Place? = Settings.openedPlace ?? .inbox
    // A list asked for from outside the window, by a tap on a widget. The iPhone layout opens
    // it and clears this. There the inbox is a list inside Tasks, and naming it as the place
    // only leads to the list of lists.
    var requestedPlace: Place?
    // Set to open quick add from outside the window, by the home screen menu. The layout opens
    // it and clears this.
    var wantsNewItem = false
    // The item shown in the detail: the inspector on Mac and iPad, a sheet on the iPhone.
    var itemID: Int? = Settings.openedItem
    var isSearchFocused = false
    // The note open in Notes. Below zero while the server has not given it an ID yet. The
    // launch argument `-note` comes through `OpenRequest`, so a locked note asks first.
    var noteID: Int?
    // True while Notes shows the locked notes instead of the others. Set only by
    // `openLockedNotes`, after the lock has opened, and cleared when it closes.
    var isInLockedNotes = false
    // Counts the ways out of Locked Notes, so an answer that comes late does not lead there
    // after the window has left it on purpose.
    @ObservationIgnored private var lockedEntry = 0
    // The note the last way in asked for, while the question is on screen. A second request
    // in that time takes the same answer.
    @ObservationIgnored private var lockedTarget: Int??
    // True while a new, empty note is open. It ends with the note's first character.
    var isWritingNote = false
    // The project sheet, for a new project or for one that is edited.
    var projectEditor: ProjectEditor?

    // Moves an item to the trash and closes its detail. Nothing asks first: the trash gives it
    // back.
    func trash(_ id: Int, in store: Store) {
        store.update(id, ItemPatch(trashed: true))
        if itemID == id { itemID = nil }
    }

    // Opens Notes with a new note, whatever was open there.
    func writeNote() {
        lockedEntry += 1
        place = .notes
        isInLockedNotes = false
        noteID = nil
        isWritingNote = true
    }

    // Opens Locked Notes, with the note when one is named. The question comes only while the
    // lock is closed, and the notes in there open without another one. A cancel or a failure
    // leaves the window as it was.
    func openLockedNotes(note id: Int? = nil) async {
        lockedTarget = .some(id)
        let entry = lockedEntry
        guard !NoteLock.shared.isAsking else { return }
        let isOpen = await NoteLock.shared.open()
        let target = lockedTarget
        lockedTarget = nil
        guard isOpen, entry == lockedEntry, let target else { return }
        place = .notes
        isWritingNote = false
        isInLockedNotes = true
        noteID = target
    }

    // Back to the other notes, by the back button.
    func leaveLockedNotes() {
        lockedEntry += 1
        isInLockedNotes = false
        noteID = nil
    }

    // The lock closed: nothing locked stays on screen. The editor saves its text on the same
    // change, before it lets go of the note.
    func lockClosed(in store: Store) {
        lockedEntry += 1
        isInLockedNotes = false
        if let id = noteID, store.note(id)?.locked == true { noteID = nil }
    }
}
