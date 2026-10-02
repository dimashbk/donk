import Donk
import DonkUI
import SwiftUI

struct StorageDemoView: View {
    @State private var isBrowserPresented = false
    @State private var isWorking = false
    @State private var status: StorageDemoStatus?

    init() {
        StorageDemoAutorun.seedIfRequested()
    }

    var body: some View {
        List {
            Section {
                Button {
                    isBrowserPresented = true
                } label: {
                    Label("Open storage browser", systemImage: "folder.fill")
                        .font(.body.weight(.semibold))
                }
            } footer: {
                Text("Files, UserDefaults (standard + \(StorageSampleData.suiteName)), Keychain and HTTP cookies.")
            }

            Section {
                action("Seed sample data", icon: "tray.and.arrow.down.fill", tint: .accentColor) {
                    try StorageSampleData.seed()
                }
                action("Add 1,200 files", icon: "square.stack.3d.up.fill", tint: .orange) {
                    try StorageSampleData.seedBulkFiles(count: 1_200)
                }
                action("Add biometric-protected keychain item", icon: "faceid", tint: .purple) {
                    try StorageSampleData.seedProtectedKeychainItem()
                }
                action("Clear sample data", icon: "trash", tint: .red) {
                    StorageSampleData.clear()
                }
            } header: {
                Text("Sample data")
            } footer: {
                Text("Seeds Documents (JSON, text, XML and binary plists, a PNG, a SQLite database, nested folders), Caches, UserDefaults keys of every type, two keychain items and a few cookies. The biometric item uses SecAccessControl .userPresence: the Keychain list must open without a Face ID or passcode prompt, and its value asks only when you tap to authenticate.")
            }

            if let status {
                Section("Last action") {
                    Label {
                        Text(status.message)
                            .font(.footnote)
                    } icon: {
                        Image(systemName: status.isError ? "xmark.octagon.fill" : "checkmark.circle.fill")
                            .foregroundColor(status.isError ? .red : .green)
                    }
                }
            }
        }
        .navigationTitle("Files & defaults")
        .disabled(isWorking)
        .overlay {
            if isWorking {
                ProgressView()
                    .padding(24)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial))
            }
        }
        .sheet(isPresented: $isBrowserPresented) {
            StorageBrowserSheet()
        }
        .onAppear {
            StorageSampleData.configureDonkStorage()
            if ProcessInfo.processInfo.arguments.contains("-StorageDemoOpenBrowser") {
                isBrowserPresented = true
            }
        }
    }

    private func action(_ title: String, icon: String, tint: Color, work: @escaping @Sendable () throws -> String) -> some View {
        Button {
            isWorking = true
            Task {
                let result = await Task.detached(priority: .userInitiated) { () -> StorageDemoStatus in
                    do {
                        return StorageDemoStatus(message: try work(), isError: false)
                    } catch {
                        return StorageDemoStatus(message: error.localizedDescription, isError: true)
                    }
                }.value
                isWorking = false
                status = result
                DonkToast.show(result.message, tone: result.isError ? .error : .success)
            }
        } label: {
            Label(title, systemImage: icon)
                .foregroundColor(tint)
        }
    }
}

enum StorageDemoAutorun {
    private static var didSeed = false

    static func seedIfRequested() {
        guard !didSeed, ProcessInfo.processInfo.arguments.contains("-StorageDemoSeedProtected") else { return }
        didSeed = true
        StorageSampleData.configureDonkStorage()
        _ = try? StorageSampleData.seed()
        _ = try? StorageSampleData.seedProtectedKeychainItem()
    }
}

struct StorageDemoStatus: Sendable {
    let message: String
    let isError: Bool
}

struct StorageBrowserSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DonkNavigationContainer {
            DonkStorage.makeRootView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .font(.body.weight(.semibold))
                    }
                }
        }
        .donkTheme()
    }
}
