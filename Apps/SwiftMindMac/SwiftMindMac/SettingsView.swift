import AppKit
import SwiftUI

/// What the app opens on launch. Persisted as `swiftmind.launchBehavior`;
/// the default is the bundled Welcome map, which doubles as the user guide.
enum LaunchBehavior: String, CaseIterable, Identifiable {
    case help
    case last
    case brain

    static let defaultsKey = "swiftmind.launchBehavior"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .help: return "Welcome map (help & demo)"
        case .last: return "Last open map"
        case .brain: return "My Brain vaults"
        }
    }

    static var current: LaunchBehavior {
        LaunchBehavior(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .help
    }
}

struct SettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @ObservedObject private var library = VaultLibrary.shared
    @AppStorage(LaunchBehavior.defaultsKey) private var launchBehavior = LaunchBehavior.help.rawValue
    @AppStorage("swiftmind.agentBridge") private var agentBridgeEnabled = true

    var body: some View {
        TabView {
            generalTab
            vaultsTab
            agentTab
        }
        .frame(width: 460, height: 260)
    }

    private var generalTab: some View {
        Form {
            Picker("On launch, open:", selection: $launchBehavior) {
                ForEach(LaunchBehavior.allCases) { behavior in
                    Text(behavior.label).tag(behavior.rawValue)
                }
            }
            HStack {
                Button("Open Welcome Map") {
                    appModel.openHelpMap()
                }
                Spacer()
                Button("Clear Recent Maps") {
                    library.clearRecentMaps()
                }
            }
        }
        .padding()
        .tabItem { Label("General", systemImage: "gear") }
    }

    private var vaultsTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Vault folders appear in My Brain (⇧⌘B).")
                .foregroundStyle(.secondary)
            List {
                ForEach(library.vaultURLs, id: \.path) { url in
                    HStack {
                        Text(url.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button(role: .destructive) {
                            library.removeVault(url: url)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            HStack {
                Button("Add Vault…") { addVault() }
                Spacer()
            }
        }
        .padding()
        .tabItem { Label("Vaults", systemImage: "folder") }
    }

    private var agentTab: some View {
        Form {
            Toggle("Enable agent bridge (swiftmind mcp)", isOn: $agentBridgeEnabled)
            Text("Lets local AI agents read and edit the open map over a Unix socket inside this app's container — no network access. Edits land as one ⌘Z step. Takes effect on next launch.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .tabItem { Label("Agent", systemImage: "terminal") }
    }

    private func addVault() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to use as a mindmap vault"
        panel.prompt = "Add Vault"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                _ = VaultLibrary.shared.addVault(url: url)
            }
        }
    }
}
