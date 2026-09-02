import SwiftUI

struct RelayConnectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var pushManager = PushNotificationManager.shared

    @State private var urlString: String
    @State private var authSecret: String
    @State private var saveError: String?

    init() {
        let existing = RelayConfigStore.load()
        _urlString = State(initialValue: existing?.url.absoluteString ?? "")
        _authSecret = State(initialValue: existing?.authSecret ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://relay.example.com", text: $urlString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("Registration Secret", text: $authSecret)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Push-to-Start Relay")
                } footer: {
                    Text("Your self-hosted nozzlecast-relay's URL and RELAY_AUTH_SECRET. This lets a Live Activity start the instant a print begins, even while your phone is locked.")
                }

                if let saveError {
                    Section {
                        Label(saveError, systemImage: "xmark.circle.fill")
                            .foregroundStyle(NCColor.statusError)
                    }
                }

                Section {
                    Button {
                        save()
                    } label: {
                        HStack {
                            Spacer()
                            Text("Save")
                            Spacer()
                        }
                    }
                    .disabled(urlString.isEmpty || authSecret.isEmpty)
                    .listRowBackground(NCColor.accent)
                    .foregroundStyle(.white)
                }

                if RelayConfigStore.isConfigured {
                    Section {
                        Button(role: .destructive) {
                            RelayConfigStore.clear()
                            dismiss()
                        } label: {
                            HStack {
                                Spacer()
                                Text("Disconnect")
                                Spacer()
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(NCColor.canvasBackground.ignoresSafeArea())
            .navigationTitle("Push-to-Start Relay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func save() {
        do {
            _ = try RelayConfigStore.save(urlString: urlString, authSecret: authSecret)
            saveError = nil
            pushManager.startObservingPushToStartTokenIfConfigured()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
