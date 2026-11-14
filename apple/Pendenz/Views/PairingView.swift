import SwiftUI

// Shown while the device is not paired: the address of the server, a pairing code and a name
// for this device.
struct PairingView: View {
    private enum Field: Hashable {
        case server, code, name
    }

    @Environment(Session.self) private var session
    @State private var server = ""
    @State private var code = ""
    @State private var name = Session.defaultDeviceName
    @State private var isPairing = false
    @State private var failure: String?
    @FocusState private var focus: Field?

    private var isComplete: Bool {
        !server.trimmingCharacters(in: .whitespaces).isEmpty
            && code.count == PairingCodeText.length + 1
            && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pair this device")
                        .font(.title2.weight(.semibold))
                    Text(
                        "Pendenz keeps your items on your own server. To connect, enter its address and a pairing code.",
                    )
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
                if let notice = session.notice {
                    Label(notice, systemImage: "exclamationmark.triangle")
                }
            }
            Section {
                // The name of a field stays next to it, also once it is filled in.
                LabeledContent("Server") {
                    // Verbatim: read as markdown the address becomes a link, which the Mac
                    // drew in blue and away from the edge the other fields end at.
                    TextField("Server", text: $server, prompt: Text(verbatim: "https://pendenz.example.com"))
                        .labelsHidden()
                        .focused($focus, equals: .server)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .submitLabel(.next)
                        .onSubmit { focus = .code }
                        .accessibilityIdentifier("pairing-server")
                }
                LabeledContent("Code") {
                    TextField("Code", text: $code, prompt: Text("ABCDE-FGHJK"))
                        .labelsHidden()
                        .focused($focus, equals: .code)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        #endif
                        .submitLabel(.next)
                        .onSubmit { focus = .name }
                        .accessibilityIdentifier("pairing-code")
                }
                LabeledContent("Device name") {
                    TextField("Device name", text: $name, prompt: Text("iPhone"))
                        .labelsHidden()
                        .focused($focus, equals: .name)
                        .submitLabel(.go)
                        .onSubmit(pair)
                        .accessibilityIdentifier("pairing-name")
                }
            } footer: {
                Text(
                    "A paired device shows a code under Settings, Pair Another Device. For the first device, run “pendenz pairing-code” on the server. A code works once, for ten minutes.",
                )
            }
            Section {
                Button(action: pair) {
                    HStack(spacing: 8) {
                        if isPairing {
                            ProgressView()
                                .controlSize(.small)
                        }
                        // A button in the label color, so its text takes the background color
                        // to stay readable in light and dark.
                        Text(isPairing ? "Pairing" : "Pair")
                            .fontWeight(.semibold)
                            .foregroundStyle(isComplete ? AnyShapeStyle(.background) : AnyShapeStyle(.secondary))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.primary)
                .controlSize(.large)
                .disabled(!isComplete || isPairing)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("pairing-submit")
            } footer: {
                if let failure {
                    // Said in words and with an icon, not by the red alone.
                    Label(failure, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("pairing-failure")
                }
            }
        }
        .formStyle(.grouped)
        // The form keeps a width that reads well. On iOS its background is drawn behind it
        // across the whole screen, so a wide iPad shows no column of another color. The Mac
        // draws a grouped form on the window's own background.
        #if os(iOS)
        .scrollContentBackground(.hidden)
        #endif
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(iOS)
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        #endif
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 440)
        #endif
        .onAppear {
            if server.isEmpty { server = session.lastServer }
            focus = server.isEmpty ? .server : .code
        }
        .onChange(of: code) { _, typed in
            let shaped = PairingCodeText.shape(typed)
            if shaped != typed { code = shaped }
        }
    }

    private func pair() {
        guard isComplete, !isPairing else { return }
        isPairing = true
        failure = nil
        Task {
            do {
                try await session.pair(server: server, code: code, name: name.trimmingCharacters(in: .whitespaces))
            } catch {
                failure = error.localizedDescription
            }
            isPairing = false
        }
    }
}

// A pairing code is ten letters and digits, written in two groups of five.
enum PairingCodeText {
    static let length = 10

    // What was typed, in upper case, without anything that is not a letter or digit, and with
    // the hyphen in its place.
    static func shape(_ typed: String) -> String {
        let plain = typed.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(length)
        guard plain.count > length / 2 else { return String(plain) }
        return plain.prefix(length / 2) + "-" + plain.dropFirst(length / 2)
    }
}
