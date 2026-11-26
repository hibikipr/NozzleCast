import SwiftUI

struct BambuddyConnectionSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var serverURLString: String
    @State private var apiKey: String
    @State private var isTesting = false
    @State private var testResult: TestResult?
    @State private var testTask: Task<Void, Never>?

    private enum TestResult: Equatable {
        case success(String)
        case failure(String)
    }

    init() {
        _serverURLString = State(initialValue: "")
        _apiKey = State(initialValue: "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("printer-server.example.com", text: $serverURLString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("API Key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Printer Server")
                } footer: {
                    Text("Find your API key in your server's Settings → API Keys. It needs Read Status and Manage Inventory permissions.")
                }

                if let testResult {
                    Section {
                        switch testResult {
                        case .success(let username):
                            Label("Connected as \(username)", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(NCColor.statusPrinting)
                        case .failure(let message):
                            Label(message, systemImage: "xmark.circle.fill")
                                .foregroundStyle(NCColor.statusError)
                        }
                    }
                }

                Section {
                    Button {
                        testTask?.cancel()
                        testTask = Task { await testAndSave() }
                    } label: {
                        HStack {
                            Spacer()
                            if isTesting {
                                ProgressView().tint(NCColor.onAccent)
                            } else {
                                Text("Save & Test Connection")
                            }
                            Spacer()
                        }
                    }
                    .disabled(
                        serverURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || isTesting
                    )
                    .listRowBackground(NCColor.accent)
                    .foregroundStyle(NCColor.onAccent)
                }

                if store.config.isConfigured {
                    Section {
                        Button(role: .destructive) {
                            store.config.clear()
                            store.loadMockData()
                            store.connectionStatus = .notConfigured
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
            .navigationTitle("Connect Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        testTask?.cancel()
                        dismiss()
                    }
                }
            }
            .onAppear {
                serverURLString = store.config.serverURLString
                apiKey = store.config.apiKey
            }
            .onDisappear {
                testTask?.cancel()
            }
        }
        .preferredColorScheme(.dark)
    }

    private func testAndSave() async {
        let trimmedURL = serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = BambuddyConfig.normalizedServerURL(from: trimmedURL) else {
            testResult = .failure("Enter a valid http:// or https:// server URL.")
            return
        }

        isTesting = true
        testResult = nil
        defer { isTesting = false }

        do {
            let probe = BambuddyAPIClient(baseURL: url, apiKey: trimmedKey)
            let me = try await probe.me()
            guard !Task.isCancelled else { return }

            store.config.serverURLString = trimmedURL
            store.config.apiKey = trimmedKey
            testResult = .success(me.username)

            await store.testConnectionAndRefresh()
            guard !Task.isCancelled else { return }

            try? await Task.sleep(for: .seconds(0.6))
            guard !Task.isCancelled else { return }
            dismiss()
        } catch {
            guard !Task.isCancelled else { return }
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            testResult = .failure(msg)
        }
    }
}
