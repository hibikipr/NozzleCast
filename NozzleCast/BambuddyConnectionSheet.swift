import SwiftUI

struct BambuddyConnectionSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var serverURLString: String
    @State private var apiKey: String
    @State private var isTesting = false
    @State private var testResult: TestResult?

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
                        Task { await testAndSave() }
                    } label: {
                        HStack {
                            Spacer()
                            if isTesting {
                                ProgressView().tint(.white)
                            } else {
                                Text("Save & Test Connection")
                            }
                            Spacer()
                        }
                    }
                    .disabled(serverURLString.isEmpty || apiKey.isEmpty || isTesting)
                    .listRowBackground(NCColor.accent)
                    .foregroundStyle(.white)
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
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                serverURLString = store.config.serverURLString
                apiKey = store.config.apiKey
            }
        }
        .preferredColorScheme(.dark)
    }

    private func testAndSave() async {
        isTesting = true
        testResult = nil
        store.config.serverURLString = serverURLString
        store.config.apiKey = apiKey

        let success = await store.testConnectionAndRefresh()
        isTesting = false

        switch store.connectionStatus {
        case .connected(let username):
            testResult = .success(username)
            try? await Task.sleep(for: .seconds(0.6))
            dismiss()
        case .failed(let message):
            testResult = .failure(message)
        default:
            break
        }
        _ = success
    }
}
