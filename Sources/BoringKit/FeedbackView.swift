import SwiftUI

/// A ready-made feedback sheet: `.sheet(isPresented: $showFeedback) { FeedbackView() }`
public struct FeedbackView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var email = ""
    @State private var sending = false
    @State private var failed = false

    public init() {}

    private var canSend: Bool {
        !sending && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("What's on your mind?") {
                    TextEditor(text: $message)
                        .frame(minHeight: 160)
                        .accessibilityLabel("Feedback")
                }
                Section {
                    TextField("Email (optional)", text: $email)
                        .textContentType(.emailAddress)
                        #if os(iOS)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                } footer: {
                    Text("Only if you'd like a reply.")
                }
                if failed {
                    Section {
                        Label {
                            Text("Couldn't send. Check your connection and try again.")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        }
                    }
                }
            }
            .formStyle(.grouped)  // the iOS look; a Mac would lay the form out like a settings pane
            .navigationTitle("Feedback")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #else
                .frame(minWidth: 420, minHeight: 380)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if sending {
                        ProgressView().accessibilityLabel("Sending")
                    } else {
                        Button("Send") { Task { await send() } }.disabled(!canSend)
                    }
                }
            }
        }
    }

    private func send() async {
        sending = true
        failed = false
        let sent = await BoringKit.sendFeedback(message, email: email.trimmingCharacters(in: .whitespaces))
        sending = false
        if sent { dismiss() } else { failed = true }
    }
}
