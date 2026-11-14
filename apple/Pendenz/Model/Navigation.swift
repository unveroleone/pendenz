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
    // The note open in Notes. Below zero while the server has not given it an ID yet.
    var noteID: Int? = Settings.openedNote
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
        place = .notes
        noteID = nil
        isWritingNote = true
    }
}
