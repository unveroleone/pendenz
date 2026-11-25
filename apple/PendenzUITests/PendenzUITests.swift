import XCTest

// Flows that need a finger: swipes, drags, the notification prompt, typing a pairing code,
// searching, putting back from the trash, deleting a project, the attachments of a note and
// sharing a page from Safari.
// They run against servers that `apple/uitest.sh` starts and seeds. Without its environment
// every test is skipped.
@MainActor
final class PendenzUITests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func value(_ name: String) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
            throw XCTSkip("Run apple/uitest.sh, which sets \(name).")
        }
        return value
    }

    // The app against the seeded server in local mode, which needs no pairing.
    private func launch(tab: String) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = try ["-apiURL", value("PENDENZ_LOCAL"), "-tab", tab]
        app.launch()
        return app
    }

    private func openInbox(_ app: XCUIApplication) {
        let inbox = app.staticTexts["Inbox"].firstMatch
        XCTAssertTrue(inbox.waitForExistence(timeout: 10))
        inbox.tap()
    }

    // A row of a list: the button that carries the item's title.
    private func row(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    private var isSidebarLayout: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    func testSwipeRightCompletes() throws {
        try XCTSkipIf(isSidebarLayout, "Runs on the iPhone layout.")
        let app = try launch(tab: "tasks")
        openInbox(app)
        let item = row(app, "Swipe right")
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        // A full swipe: from the left of the row to beyond the right edge of the screen.
        item.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
            .press(
                forDuration: 0.05,
                thenDragTo: item.coordinate(withNormalizedOffset: CGVector(dx: 1.4, dy: 0.5)),
                withVelocity: .fast,
                thenHoldForDuration: 0,
            )
        // The row lingers for two seconds, then leaves the list.
        XCTAssertTrue(item.waitForNonExistence(timeout: 10))
    }

    func testSwipeLeftOffersTomorrowAndTrash() throws {
        try XCTSkipIf(isSidebarLayout, "Runs on the iPhone layout.")
        let app = try launch(tab: "tasks")
        openInbox(app)
        let item = row(app, "Swipe left")
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        item.swipeLeft()
        XCTAssertTrue(app.buttons["Trash"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Today"].exists)
        app.buttons["Tomorrow"].tap()
        let dated = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH 'Swipe left' AND label CONTAINS 'Tomorrow'")).firstMatch
        XCTAssertTrue(dated.waitForExistence(timeout: 5))
        item.swipeLeft()
        // The trash asks nothing: it gives the item back.
        app.buttons["Trash"].tap()
        XCTAssertTrue(item.waitForNonExistence(timeout: 10))
    }

    func testLongPressOpensTheMenu() throws {
        try XCTSkipIf(isSidebarLayout, "Runs on the iPhone layout.")
        let app = try launch(tab: "tasks")
        openInbox(app)
        let item = row(app, "Drag B")
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        item.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Due"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Project"].exists)
        // One tap in the open menu: the simulator waits a minute for the menu to settle
        // before each. Not "Complete", which is also the label of every row's circle.
        app.buttons["Move to Trash"].firstMatch.tap()
        XCTAssertTrue(item.waitForNonExistence(timeout: 10), "Trashed from the menu, the row leaves the list.")
    }

    func testDragReordersTheInbox() throws {
        try XCTSkipIf(isSidebarLayout, "Runs on the iPhone layout.")
        let app = try launch(tab: "tasks")
        openInbox(app)
        let lower = row(app, "Drag A")
        let upper = row(app, "Drag C")
        XCTAssertTrue(lower.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(lower.frame.minY, upper.frame.minY, "Seeded with C above A.")
        // Dropped a little above the middle of the upper row, so it lands before it.
        let target = upper.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
        lower.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 1.0, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 0.5)
        let moved = expectation(for: NSPredicate { _, _ in lower.frame.minY < upper.frame.minY }, evaluatedWith: nil)
        wait(for: [moved], timeout: 10)
    }

    func testDragOntoProjectAndReminders() throws {
        try XCTSkipUnless(isSidebarLayout, "Runs on the iPad layout, which has the sidebar.")
        let app = try launch(tab: "reminders")
        let inbox = app.staticTexts["Inbox"].firstMatch
        XCTAssertTrue(inbox.waitForExistence(timeout: 10))
        inbox.tap()
        let item = app.staticTexts["Drag B"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        let project = app.staticTexts["Testproject"].firstMatch
        item.press(forDuration: 1.0, thenDragTo: project, withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertTrue(item.waitForNonExistence(timeout: 10), "The row left the inbox.")
        project.tap()
        XCTAssertTrue(item.waitForExistence(timeout: 10), "The row is in the project.")
        let reminders = app.staticTexts["Reminders"].firstMatch
        item.press(forDuration: 1.0, thenDragTo: reminders, withVelocity: .slow, thenHoldForDuration: 0.5)
        reminders.tap()
        XCTAssertTrue(item.waitForExistence(timeout: 10), "The row is due today.")
    }

    func testReminderFires() throws {
        try XCTSkipIf(isSidebarLayout, "Runs on the iPhone layout.")
        let app = try launch(tab: "reminders")
        // A due time at least a minute ahead, on the full minute.
        let due = Date(timeIntervalSince1970: ((Date.now.timeIntervalSince1970 + 60) / 60).rounded(.up) * 60)
        let clock = due
            .formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
                .locale(Locale(identifier: "de_CH")))
        let add = app.buttons["New item"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Reminder test \(clock)\n")
        // Leave quick add with a tap outside its sheet.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        let turnOn = app.buttons["Turn On"].firstMatch
        if turnOn.waitForExistence(timeout: 5) {
            turnOn.tap()
            let allow = springboard.buttons["Allow"].firstMatch
            XCTAssertTrue(allow.waitForExistence(timeout: 10), "iOS asks for notifications.")
            allow.tap()
            XCTAssertTrue(turnOn.waitForNonExistence(timeout: 5))
        }
        XCUIDevice.shared.press(.home)
        let banner = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Reminder test'")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 150), "The reminder arrives as a notification.")
    }

    func testNoteIsWrittenAndTurnedIntoAnItem() throws {
        try XCTSkipIf(isSidebarLayout, "Runs on the iPhone layout.")
        let app = try launch(tab: "notes")
        let new = app.buttons["New Note"].firstMatch
        XCTAssertTrue(new.waitForExistence(timeout: 10))
        new.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("Written by the test\nCall the plumber")
        app.navigationBars.buttons.firstMatch.tap()
        let note = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Written by the test'")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 5), "The note is in the list.")
        note.tap()
        app.buttons["More"].firstMatch.tap()
        app.buttons["Turn Note into Item"].firstMatch.tap()
        // The new item opens in its detail.
        XCTAssertTrue(app.staticTexts["Steps"].firstMatch.waitForExistence(timeout: 10) || app.buttons["Done"]
            .firstMatch.waitForExistence(timeout: 5))
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(note.waitForNonExistence(timeout: 10), "The note went to the trash.")
    }

    // A note shows its picture and its file under the text, opens the picture in the preview, and
    // removes it after asking. The server seeded both.
    func testNoteShowsOpensAndRemovesAttachments() throws {
        try XCTSkipIf(isSidebarLayout, "Runs on the iPhone layout.")
        let server = try value("PENDENZ_LOCAL")
        let id = try value("PENDENZ_NOTE_ID")
        let app = try launch(tab: "notes")
        let note = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Attachments'")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 10), "The note is in the list.")
        note.tap()
        // The exact label once the picture has loaded; until then it ends in ", loading".
        let picture = app.buttons["Image 1 of 1"].firstMatch
        XCTAssertTrue(picture.waitForExistence(timeout: 20), "The picture is under the text.")
        let file = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reminder.txt'")).firstMatch
        XCTAssertTrue(file.exists, "So is the file.")

        picture.tap()
        let close = app.buttons.matching(NSPredicate(format: "label IN {'Close', 'Done'}")).firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10), "The picture opens in the preview.")
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 10))

        picture.press(forDuration: 2)
        app.buttons["Remove"].firstMatch.tap()
        let alert = app.alerts["Remove this image?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "Removing asks first.")
        alert.buttons["Remove"].tap()
        XCTAssertTrue(picture.waitForNonExistence(timeout: 10), "The picture is gone.")
        XCTAssertTrue(file.exists, "The file stays.")

        var names: [String]?
        let deadline = Date.now.addingTimeInterval(15)
        while names != ["Reminder.txt"], Date.now < deadline {
            names = try files(ofNote: id, on: server)
            if names != ["Reminder.txt"] { Thread.sleep(forTimeInterval: 0.5) }
        }
        XCTAssertEqual(names, ["Reminder.txt"], "The server removed the picture and kept the file.")
        app.navigationBars.buttons.firstMatch.tap()
    }

    private func files(ofNote id: String, on server: String) throws -> [String] {
        let data = try Data(contentsOf: URL(string: server + "/api/notes/\(id)")!)
        let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let note = body?["note"] as? [String: Any]
        return (note?["files"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }

    // Return in the description starts a new line, and the server keeps it.
    func testDescriptionKeepsParagraphs() throws {
        try XCTSkipIf(isSidebarLayout, "Runs on the iPhone layout.")
        let server = try value("PENDENZ_LOCAL")
        let app = try launch(tab: "tasks")
        openInbox(app)
        let item = row(app, "Paragraphs")
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        item.tap()
        let notes = app.textViews["Notes"].exists ? app.textViews["Notes"] : app.textFields["Notes"]
        XCTAssertTrue(notes.waitForExistence(timeout: 5))
        notes.tap()
        notes.typeText("First line\n\nSecond paragraph")
        app.buttons["Done"].firstMatch.tap()

        let expected = "First line\n\nSecond paragraph"
        var stored: String?
        let deadline = Date.now.addingTimeInterval(15)
        while stored != expected, Date.now < deadline {
            stored = try description(of: "Paragraphs", on: server)
            if stored != expected { Thread.sleep(forTimeInterval: 0.5) }
        }
        XCTAssertEqual(stored, expected, "The server keeps the line breaks.")

        item.tap()
        let reopened = app.textViews["Notes"].exists ? app.textViews["Notes"] : app.textFields["Notes"]
        XCTAssertTrue(reopened.waitForExistence(timeout: 5))
        XCTAssertEqual(reopened.value as? String, expected, "The detail shows the line breaks.")
        // The window would open the next launch on this item again.
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(reopened.waitForNonExistence(timeout: 5))
    }

    private func description(of title: String, on server: String) throws -> String? {
        try items(titled: title, on: server).first?["description"] as? String
    }

    // A page shared from Safari waits in the app group and lands in the inbox, with its link,
    // when the app comes to the front.
    func testSharesALinkFromSafari() throws {
        try XCTSkipIf(isSidebarLayout, "Runs on the iPhone layout.")
        let server = try value("PENDENZ_LOCAL")
        // Opened once, the app tells the extension which server it is paired with.
        let app = try launch(tab: "tasks")
        openInbox(app)

        let nonce = UUID().uuidString.prefix(8)
        let link = server + "/healthz?shared=\(nonce)"
        let name = "Shared from Safari \(nonce)"
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        try safari.open(XCTUnwrap(URL(string: link)))
        // The share button is in the page menu of the bottom bar.
        let menu = safari.buttons["MoreMenuButton"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 15))
        menu.tap()
        let share = safari.buttons["ShareButton"].firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        share.tap()
        let pendenz = safari.cells["Pendenz"].firstMatch
        XCTAssertTrue(pendenz.waitForExistence(timeout: 10), "Pendenz is offered in the share sheet.")
        for _ in 0 ..< 3 where !pendenz.isHittable {
            safari.collectionViews["activityCollectionView"].firstMatch.swipeLeft()
        }
        pendenz.tap()

        // The extension's sheet is drawn inside Safari.
        let title = safari.descendants(matching: .any)["share-title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        // The caret at the very end, then every character before it deleted.
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.9)).tap()
        let typed = title.value as? String ?? ""
        title.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: typed.count + 5) + name)
        XCTAssertEqual(title.value as? String, name)
        let add = safari.buttons["share-add"].firstMatch
        add.tap()
        XCTAssertTrue(add.waitForNonExistence(timeout: 10), "The sheet closes.")

        app.activate()
        XCTAssertTrue(row(app, name).waitForExistence(timeout: 15), "The share is in the inbox.")
        var stored: [[String: Any]] = []
        let deadline = Date.now.addingTimeInterval(15)
        while stored.isEmpty, Date.now < deadline {
            stored = try items(titled: name, on: server)
            if stored.isEmpty { Thread.sleep(forTimeInterval: 0.5) }
        }
        XCTAssertEqual(stored.count, 1, "The server has the item once.")
        XCTAssertEqual(stored.first?["source_url"] as? String, link, "Its link is the page.")
    }

    private func items(titled title: String, on server: String) throws -> [[String: Any]] {
        var url = URLComponents(string: server + "/api/items")!
        url.queryItems = [URLQueryItem(name: "q", value: title)]
        let data = try Data(contentsOf: url.url!)
        let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let items = body?["items"] as? [[String: Any]] ?? []
        return items.filter { $0["title"] as? String == title }
    }

    func testPairsShowsDevicesAndUnpairs() throws {
        try XCTSkipIf(isSidebarLayout, "Runs on the iPhone layout.")
        let server = try value("PENDENZ_PAIRED")
        let code = try value("PENDENZ_CODE")
        let app = XCUIApplication()
        app.launchArguments = ["-tab", "tasks"]
        app.launch()
        let address = app.textFields["pairing-server"]
        if !address.waitForExistence(timeout: 5) {
            // Still paired from an earlier run.
            unpair(app)
            XCTAssertTrue(address.waitForExistence(timeout: 10))
        }
        // The field offers the address of the last pairing. A tap at its end puts the cursor
        // behind the text, so the delete keys remove all of it.
        let old = address.value as? String ?? ""
        if old != server {
            address.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
            if !old.isEmpty, old != "https://pendenz.example.com" {
                address.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
            }
            address.typeText(server)
        }
        XCTAssertEqual(address.value as? String, server)
        let codeField = app.textFields["pairing-code"]
        codeField.tap()
        // Typed without the hyphen and in lower case: the field shapes it. One key at a time,
        // since the field rewrites its text while it shapes it, and a key that comes during
        // the rewrite is lost: typed all at once, the second letter went missing.
        for key in code.replacingOccurrences(of: "-", with: "").lowercased() {
            codeField.typeText(String(key))
        }
        XCTAssertEqual(codeField.value as? String, code)
        let name = app.textFields["pairing-name"]
        name.tap()
        name.typeText(" Test")
        app.buttons["pairing-submit"].tap()
        XCTAssertTrue(
            app.staticTexts["Inbox"].firstMatch.waitForExistence(timeout: 15),
            "Paired, and the lists are on screen.",
        )

        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'This device.'")).firstMatch
            .waitForExistence(timeout: 10))
        app.buttons["Show a Pairing Code"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["settings-code"].waitForExistence(timeout: 10))
        unpairFromSettings(app)
        XCTAssertTrue(address.waitForExistence(timeout: 10), "Unpaired, and back on the pairing screen.")
    }

    func testSearchFindsItemByNumber() throws {
        try XCTSkipIf(isSidebarLayout, "Runs on the iPhone layout.")
        let id = try value("PENDENZ_SEARCH_ID")
        let app = try launch(tab: "search")
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        let item = row(app, "Lighthouse keeper")
        // The number in both forms, then a word of the title, the description and the tag.
        for query in ["P-\(id)", id, "lighthouse", "lantern", "coastal"] {
            field.tap()
            if let text = field.value as? String, !text.isEmpty, text != field.placeholderValue {
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count))
            }
            field.typeText(query)
            XCTAssertTrue(item.waitForExistence(timeout: 10), "\(query) finds the item.")
        }
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "coastal".count))
        field.typeText("P-999999")
        XCTAssertTrue(item.waitForNonExistence(timeout: 10), "Another number does not find it.")
    }

    func testTrashPutsBack() throws {
        try XCTSkipIf(isSidebarLayout, "Runs on the iPhone layout.")
        let app = try launch(tab: "tasks")
        let trash = app.staticTexts["Trash"].firstMatch
        XCTAssertTrue(trash.waitForExistence(timeout: 10))
        trash.tap()
        let item = app.buttons["Put back Trashed item"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10), "The trash lists the item.")
        item.tap()
        XCTAssertTrue(item.waitForNonExistence(timeout: 10), "Put back, the row leaves the trash.")
        let note = app.buttons["Put back Trashed note"].firstMatch
        XCTAssertTrue(note.exists, "The trash lists the note.")
        note.tap()
        XCTAssertTrue(note.waitForNonExistence(timeout: 10))
        app.navigationBars.buttons.firstMatch.tap()
        openInbox(app)
        XCTAssertTrue(row(app, "Trashed item").waitForExistence(timeout: 10), "The item is back in the inbox.")
    }

    func testProjectIsDeletedFromItsMenu() throws {
        try XCTSkipIf(isSidebarLayout, "Runs on the iPhone layout.")
        let app = try launch(tab: "tasks")
        let project = app.staticTexts["Unused project"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 10))
        project.press(forDuration: 1.2)
        // One tap in the open menu, as in the long-press test above.
        app.buttons["Delete Project"].firstMatch.tap()
        // The delete asks first, in an alert, and says where the item goes.
        let confirm = app.alerts.buttons["Delete Project"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Its open item moves to the inbox."].firstMatch.exists)
        confirm.tap()
        XCTAssertTrue(project.waitForNonExistence(timeout: 10), "The project left the list.")
        openInbox(app)
        XCTAssertTrue(row(app, "Project item").waitForExistence(timeout: 10), "Its item is in the inbox.")
    }

    func testProjectIsDeletedFromItsEditor() throws {
        try XCTSkipIf(isSidebarLayout, "Runs on the iPhone layout.")
        let app = try launch(tab: "tasks")
        let project = app.staticTexts["Vacant project"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 10))
        project.press(forDuration: 1.2)
        app.buttons["Edit"].firstMatch.tap()
        let delete = app.buttons["project-delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 10))
        delete.tap()
        let confirm = app.alerts.buttons["Delete Project"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["It has no open items and no notes."].firstMatch.exists)
        confirm.tap()
        XCTAssertTrue(project.waitForNonExistence(timeout: 10), "The sheet closed and the project left the list.")
    }

    private func unpair(_ app: XCUIApplication) {
        app.buttons["Settings"].firstMatch.tap()
        unpairFromSettings(app)
    }

    private func unpairFromSettings(_ app: XCUIApplication) {
        let unpair = app.buttons["Unpair This Device"].firstMatch
        // Below the fold the form has not built the button yet.
        if !unpair.waitForExistence(timeout: 3) || !unpair.isHittable { app.swipeUp() }
        XCTAssertTrue(unpair.waitForExistence(timeout: 10))
        unpair.tap()
        let confirm = app.alerts.buttons["Unpair"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
    }
}
