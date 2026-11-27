import SwiftUI

// The comments on an item, oldest first, mostly the questions, plans and results of agents. The
// section is only there when the item has comments, and it shows the latest one: the earlier
// ones open with a row above it. The header folds the whole section away, and the app keeps
// that choice for every item. A long press or a right click edits a comment, marks it as
// outdated or deletes it; on the iPhone and iPad a swipe does the same.
struct ItemCommentsSection: View {
    @Environment(Store.self) private var store
    let itemID: Int

    @AppStorage("commentsFolded") private var isFolded = false
    @State private var showsEarlier = false

    var body: some View {
        let all = store.comments(of: itemID)
        if let latest = all.last {
            let earlier = all.dropLast()
            Section {
                if !isFolded {
                    rows(latest: latest, earlier: earlier)
                }
            } header: {
                header(count: all.count)
            }
            #if os(iOS)
            // A folded section is its header alone, without the gap of an empty card below it.
            .listSectionSpacing(isFolded ? .compact : .default)
            #endif
        }
    }

    // The section's title is the control: the whole width answers a tap, and the count stays
    // in sight while the comments are folded away.
    private func header(count: Int) -> some View {
        Button {
            withAnimation { isFolded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Text("Comments")
                Text(count, format: .number)
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isFolded ? -90 : 0))
                    .accessibilityHidden(true)
            }
            // Taller to the finger than to the eye: the header keeps the height of the others.
            .contentShape(.rect.inset(by: -10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count == 1 ? "1 Comment" : "\(count) Comments")
        .accessibilityValue(isFolded ? "Folded" : "Shown")
        .accessibilityHint(isFolded ? "Shows the comments" : "Folds the comments away")
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func rows(latest: Comment, earlier: ArraySlice<Comment>) -> some View {
        if !earlier.isEmpty {
            Button {
                withAnimation { showsEarlier.toggle() }
            } label: {
                // Words alone: the chevron belongs to the header, which folds the whole section.
                Text(showsEarlier ? "Hide Earlier Comments" : earlierTitle(earlier.count))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if showsEarlier {
                ForEach(earlier) { CommentRow(comment: $0) }
            }
        }
        // By its ID: when a newer comment arrives, this row's state stays with its own.
        CommentRow(comment: latest)
            .id(latest.id)
    }

    private func earlierTitle(_ count: Int) -> String {
        count == 1 ? "Show 1 Earlier Comment" : "Show \(count) Earlier Comments"
    }
}

// One comment: who wrote it and when, then its text. An outdated comment is dimmed and says so
// in words, not by its shade alone. A long text shows six lines until it is tapped.
private struct CommentRow: View {
    @Environment(Store.self) private var store
    let comment: Comment

    @State private var isExpanded = false
    @State private var isEditing = false
    @State private var isAskingToDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(store.authorName(comment.authorId))
                    .font(.subheadline.weight(.semibold))
                Text(when)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if comment.outdated {
                    // Outlined, not filled, and in the text's full color: at this size a dimmer
                    // shade falls below the contrast small text needs.
                    Text("Outdated")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(Capsule().strokeBorder(.tertiary))
                }
            }
            .lineLimit(1)
            Text(Self.text(comment.body))
                .foregroundStyle(comment.outdated ? .secondary : .primary)
                .lineLimit(isExpanded ? nil : 6)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .contentShape(.rect)
        .onTapGesture { withAnimation { isExpanded.toggle() } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAction(named: "Edit") { isEditing = true }
        .accessibilityAction(named: comment.outdated ? "Mark as Current" : "Mark as Outdated", toggleOutdated)
        .accessibilityAction(named: "Delete") { isAskingToDelete = true }
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { Clipboard.copy(comment.body) }
            Button("Edit", systemImage: "pencil") { isEditing = true }
            outdatedButton
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { isAskingToDelete = true }
        }
        #if os(iOS)
        .swipeActions(edge: .leading) {
            outdatedButton
        }
        .swipeActions(edge: .trailing) {
            // Without a role: a destructive swipe would take the row away before the question.
            Button("Delete", systemImage: "trash") { isAskingToDelete = true }
                .tint(.red)
            Button("Edit", systemImage: "pencil") { isEditing = true }
        }
        #endif
        // A deleted comment does not come back, so this asks.
        .alert("Delete this comment?", isPresented: $isAskingToDelete) {
            Button("Delete", role: .destructive) { store.delete(comment) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It is deleted on every device, and agents no longer see it.")
        }
        .sheet(isPresented: $isEditing) {
            CommentEditor(comment: comment)
        }
    }

    private var outdatedButton: some View {
        Button(
            comment.outdated ? "Mark as Current" : "Mark as Outdated",
            systemImage: comment.outdated ? "arrow.uturn.backward" : "clock.badge.xmark",
            action: toggleOutdated,
        )
    }

    private func toggleOutdated() {
        store.update(comment, CommentPatch(outdated: !comment.outdated))
    }

    private var when: String {
        let time = comment.created.map(Self.time) ?? ""
        return comment.isEdited ? "\(time), edited" : time
    }

    private var accessibilityText: String {
        var parts = [store.authorName(comment.authorId), when]
        if comment.outdated { parts.append("outdated") }
        // The text as shown, without the marks of the markdown.
        parts.append(String(Self.text(comment.body).characters))
        return parts.joined(separator: ", ")
    }

    // The time alone today, "Yesterday" and the time the day before, the day and the time
    // otherwise, with the year when it is another one.
    private static func time(_ date: Date) -> String {
        let calendar = Calendar.current
        let clock = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return clock }
        if calendar.isDateInYesterday(date) { return "Yesterday, \(clock)" }
        let day: Date.FormatStyle = calendar.isDate(date, equalTo: .now, toGranularity: .year)
            ? .dateTime.day().month(.abbreviated)
            : .dateTime.day().month(.abbreviated).year()
        return "\(date.formatted(day)), \(clock)"
    }

    // Agents often write links and bold words in markdown. Those show as such, and so does an
    // address written out plainly; everything else, line breaks included, stays as written.
    private static func text(_ body: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var text = (try? AttributedString(markdown: body, options: options)) ?? AttributedString(body)
        let plain = String(text.characters)
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        for match in detector?.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) ?? [] {
            guard let url = match.url, let range = Range(match.range, in: plain) else { continue }
            let characters = text.characters
            let lower = characters.index(
                text.startIndex, offsetBy: plain.distance(from: plain.startIndex, to: range.lowerBound),
            )
            let upper = characters.index(lower, offsetBy: plain.distance(from: range.lowerBound, to: range.upperBound))
            // A link the markdown already made stays as it is.
            guard text[lower ..< upper].link == nil else { continue }
            text[lower ..< upper].link = url
        }
        for run in text.runs {
            guard let link = run.link else { continue }
            if Links.opens(link) {
                // The tint is black or white, so a link is told apart by its line.
                text[run.range].underlineStyle = .single
            } else {
                // A markdown link shows its label, not where it goes. One that would open
                // another app, such as a shortcut, stays plain text.
                text[run.range].link = nil
            }
        }
        return text
    }
}

// Changes the text of a comment. Saving an empty text is not offered; deleting is.
private struct CommentEditor: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let comment: Comment

    @State private var text = ""
    @FocusState private var isFocused: Bool

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .focused($isFocused)
                .padding(.horizontal)
                .navigationTitle("Edit Comment")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            store.update(comment, CommentPatch(body: trimmed))
                            dismiss()
                        }
                        // Counted as the server counts, in Unicode scalars.
                        .disabled(
                            trimmed.isEmpty || trimmed == comment.body
                                || trimmed.unicodeScalars.count > Comment.bodyLimit,
                        )
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 260)
        #endif
        .onAppear {
            text = comment.body
            isFocused = true
        }
    }
}
