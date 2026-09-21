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

/// Display size for inline media (images in notes, sketch boards), picked in
/// Settings. Persisted as `swiftmind.mediaSize`; small matches a Mac app icon.
enum MediaSizeLevel: String, CaseIterable, Identifiable {
    case small
    case medium
    case large

    static let defaultsKey = "swiftmind.mediaSize"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .small: return "Small (app-icon size)"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }

    /// Square display box (points) media content scales to fit inside.
    var points: Double {
        switch self {
        case .small: return 64
        case .medium: return 160
        case .large: return 320
        }
    }

    static var current: MediaSizeLevel {
        MediaSizeLevel(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .medium
    }
}

/// Where note editing happens (⌘E / double-click / `e`). Persisted as
/// `swiftmind.noteEditMode`; `panel` is the floating/in-place overlay editor,
/// `onCard` hosts the same editor at an expanded note card's frame.
enum NoteEditMode: String, CaseIterable, Identifiable {
    case panel
    case onCard

    static let defaultsKey = "swiftmind.noteEditMode"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .panel: return "Floating panel"
        case .onCard: return "Directly on card"
        }
    }

    static var current: NoteEditMode {
        NoteEditMode(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .panel
    }
}

struct SettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @ObservedObject private var library = VaultLibrary.shared
    @AppStorage(LaunchBehavior.defaultsKey) private var launchBehavior = LaunchBehavior.help.rawValue
    @AppStorage(MediaSizeLevel.defaultsKey) private var mediaSize = MediaSizeLevel.medium.rawValue
    @AppStorage(NoteEditMode.defaultsKey) private var noteEditMode = NoteEditMode.panel.rawValue
    @AppStorage("swiftmind.agentBridge") private var agentBridgeEnabled = true

    var body: some View {
        TabView {
            generalTab
            vaultsTab
            agentTab
        }
        .frame(width: 460, height: 380)
    }

    private var generalTab: some View {
        Form {
            Picker("On launch, open:", selection: $launchBehavior) {
                ForEach(LaunchBehavior.allCases) { behavior in
                    Text(behavior.label).tag(behavior.rawValue)
                }
            }
            Picker("Inline media size:", selection: $mediaSize) {
                ForEach(MediaSizeLevel.allCases) { level in
                    Text(level.label).tag(level.rawValue)
                }
            }
            Text("Images in notes and hand-drawn sketch boards scale to fit this size.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Section("Notes") {
                Picker("Note editing:", selection: $noteEditMode) {
                    ForEach(NoteEditMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .accessibilityIdentifier("noteEditModePicker")
                Text("“Directly on card” edits expanded note cards in place on the canvas (press X on a node to expand its note). Applies immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            Link("Privacy Policy", destination: AppLinks.privacyPolicy)
                .accessibilityIdentifier("privacyPolicyLink")
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
