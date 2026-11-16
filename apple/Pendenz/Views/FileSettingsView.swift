import SwiftUI

// The largest file that can be added to an item. The limit belongs to the server and holds for
// every device, so it is read from there and set there, not queued: without a connection the
// slider goes back to what the server last confirmed.
struct FileSettingsView: View {
    @Environment(Session.self) private var session

    // What the server confirmed last. The slider starts there and returns there after a failure.
    @State private var confirmed: ServerSettings?
    @State private var value: Double = 25
    @State private var isEditing = false
    // The value that waits to be sent while a request for another one is on its way.
    @State private var wanted: Int?
    @State private var isSaving = false
    @State private var isLoading = false
    @State private var failure: String?

    var body: some View {
        Form {
            Section {
                if let confirmed {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Largest file", value: "\(Int(value)) MB")
                            .accessibilityHidden(true)
                        // Whole megabytes, rounded here rather than with a step: a slider with a
                        // step draws a tick per step under its track, and a hundred of them read
                        // as a second line.
                        Slider(
                            value: Binding(get: { value }, set: { value = $0.rounded() }),
                            in: 1 ... Double(max(confirmed.fileLimitCeilingMb, 1)),
                        ) {
                            Text("Largest file")
                        } minimumValueLabel: {
                            Text("1 MB")
                        } maximumValueLabel: {
                            Text("\(confirmed.fileLimitCeilingMb) MB")
                        } onEditingChanged: { editing in
                            isEditing = editing
                        }
                        // The fill of the track in the black or white of the text.
                        .tint(.primary)
                        .accessibilityValue("\(Int(value)) megabytes")
                    }
                    .padding(.vertical, 4)
                } else if isLoading {
                    ProgressView()
                } else {
                    Text(unavailable)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if let failure {
                        Label(failure, systemImage: "exclamationmark.circle")
                    }
                    if confirmed != nil {
                        Text("Applies to files added from now on, on every device. Files already attached stay.")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Files")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
        // Sent once the slider is let go. A value set without a drag, such as by VoiceOver,
        // is sent a moment after the last change.
        .task(id: Pending(value: Int(value), isEditing: isEditing)) {
            guard !isEditing, let confirmed, Int(value) != confirmed.fileLimitMb else { return }
            try? await Task.sleep(for: .seconds(0.4))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    private struct Pending: Hashable {
        let value: Int
        let isEditing: Bool
    }

    private var unavailable: String {
        if let version = session.store?.serverVersion, version < .minimum {
            return "Your server runs \(version). Files need \(ServerVersion.minimum) or newer."
        }
        return "The limit is shown once the server can be reached."
    }

    private func load() async {
        // What this device knows, until the server answers.
        if confirmed == nil, let known = session.store?.settings { show(known) }
        isLoading = true
        defer { isLoading = false }
        do {
            try await show(session.serverSettings())
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    private func show(_ settings: ServerSettings) {
        confirmed = settings
        if !isEditing { value = Double(settings.fileLimitMb) }
    }

    // One request at a time. A value chosen while one is on its way goes after it.
    private func save() {
        wanted = Int(value)
        guard !isSaving else { return }
        isSaving = true
        Task {
            var hasFailed = false
            while let target = wanted, target != confirmed?.fileLimitMb {
                wanted = nil
                do {
                    let saved = try await session.setFileLimit(target)
                    confirmed = saved
                    // A value chosen while this one was on its way stays on the slider and goes
                    // out next. Only the value that was sent is replaced by the server's.
                    if !isEditing, Int(value) == target { value = Double(saved.fileLimitMb) }
                    failure = nil
                } catch is URLError {
                    // No answer: the server may have taken the value or not. It is asked what
                    // it holds now, and the slider shows that.
                    failure = "The server could not be reached, so the limit may not have changed."
                    if let now = try? await session.serverSettings() { show(now) }
                    wanted = nil
                    hasFailed = true
                } catch {
                    failure = error.localizedDescription
                    wanted = nil
                    hasFailed = true
                }
            }
            isSaving = false
            // Back to what the server holds, after a failure or a refusal. After a success the
            // slider keeps a value chosen since, which its own wait sends.
            if hasFailed, !isEditing, let confirmed { value = Double(confirmed.fileLimitMb) }
        }
    }
}
