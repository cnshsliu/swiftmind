import SwiftUI
import SwiftMindCore

@main
struct SwiftMindMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appModel = AppModel()

    init() {
        // UI tests / automation: skip state restoration noise.
        if ProcessInfo.processInfo.arguments.contains("-uitesting") {
            UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
            UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
        }
        // Never let debugger boolean tokens be treated as open-document paths.
        UserDefaults.standard.set(false, forKey: "NSDocumentRevisionsDebugMode")
    }

    var body: some Scene {
        WindowGroup {
            ContentView(appModel: appModel)
                .environmentObject(appModel)
                .onAppear {
                    appModel.bootstrap()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Map") {
                    appModel.createAndOpenMap()
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Open Map…") {
                    appModel.openMapPanel()
                }
                .keyboardShortcut("o", modifiers: .command)

                Divider()

                Button("My Brain") {
                    appModel.showBrain()
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])

                Button("Add Vault…") {
                    appModel.addVaultPanel()
                }
            }

            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    appModel.saveCurrentMap()
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(appModel.isBrainMode || appModel.currentMapURL == nil)
            }

            CommandGroup(replacing: .undoRedo) {
                SessionUndoRedoCommands()
            }

            CommandGroup(after: .sidebar) {
                SessionCommandPaletteCommands()
            }

            CommandMenu("Node") {
                SessionNodeCommands()
            }
        }
    }
}

// MARK: - App menu commands (bound via FocusedValues)

private struct SessionUndoRedoCommands: View {
    @FocusedValue(\.documentSession) private var session

    var body: some View {
        Button("Undo") {
            session?.undo()
        }
        .keyboardShortcut("z", modifiers: .command)
        .disabled(!(session?.canUndo ?? false) || (session?.isBrainMode ?? false))

        Button("Redo") {
            session?.redo()
        }
        .keyboardShortcut("z", modifiers: [.command, .shift])
        .disabled(!(session?.canRedo ?? false) || (session?.isBrainMode ?? false))
    }
}

private struct SessionCommandPaletteCommands: View {
    @FocusedValue(\.presentCommandPalette) private var presentCommandPalette

    var body: some View {
        Button("Command Palette…") {
            presentCommandPalette?.wrappedValue = true
        }
        .keyboardShortcut("k", modifiers: .command)
        .disabled(presentCommandPalette == nil)
    }
}

private struct SessionNodeCommands: View {
    @FocusedValue(\.documentSession) private var session
    @FocusedValue(\.appModel) private var appModel

    private var canAddSibling: Bool {
        guard let session, !session.isBrainMode,
              let primary = session.store.selection.primary else { return false }
        return primary != session.store.map.root.id
    }

    private var canDelete: Bool {
        guard let session, !session.isBrainMode else { return false }
        let root = session.store.map.root.id
        return session.store.selection.selectedIDs.contains { $0 != root }
    }

    var body: some View {
        Button("Add Child") {
            guard let session, !session.isBrainMode else { return }
            let parent = session.store.selection.primary ?? session.store.map.root.id
            session.apply(InsertChildCommand(parentID: parent, text: "New Idea", side: .auto))
        }
        .keyboardShortcut("t", modifiers: .command)
        .disabled(session == nil || (session?.isBrainMode ?? false))

        Button("Add Sibling") {
            guard let session, !session.isBrainMode,
                  let primary = session.store.selection.primary,
                  primary != session.store.map.root.id else { return }
            session.apply(InsertSiblingCommand(siblingID: primary, text: "New Idea", side: .auto))
        }
        .keyboardShortcut("t", modifiers: [.command, .shift])
        .disabled(!canAddSibling)

        Button("Delete") {
            guard let session, !session.isBrainMode else { return }
            let root = session.store.map.root.id
            let ids = session.store.selection.selectedIDs.filter { $0 != root }
            guard !ids.isEmpty else { return }
            session.apply(DeleteNodesCommand(nodeIDs: Array(ids)))
        }
        .keyboardShortcut(.delete, modifiers: [])
        .disabled(!canDelete)

        Button("Open Selection") {
            appModel?.activateSelection()
        }
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!(session?.isBrainMode ?? false))

        Button("Toggle Fold") {
            if let appModel, session?.isBrainMode == true {
                appModel.toggleFoldSelection()
            } else if let session,
                      let primary = session.store.selection.primary,
                      let node = session.store.map.node(id: primary) {
                session.apply(SetFoldedCommand(nodeID: primary, isFolded: !node.isFolded))
            }
        }
        .keyboardShortcut(".", modifiers: .command)
        .disabled(session?.store.selection.primary == nil)

        Divider()

        Button(pinMenuTitle) {
            togglePin()
        }
        .keyboardShortcut("p", modifiers: [.command, .shift])
        .disabled(session?.store.selection.primary == nil || (session?.isBrainMode ?? false))
    }

    private var pinMenuTitle: String {
        guard let session,
              let primary = session.store.selection.primary,
              let node = session.store.map.node(id: primary),
              node.positionPin != nil else {
            return "Pin"
        }
        return "Unpin"
    }

    private func togglePin() {
        guard let session, !session.isBrainMode,
              let primary = session.store.selection.primary else { return }
        if let node = session.store.map.node(id: primary), node.positionPin != nil {
            session.apply(SetPinCommand(nodeID: primary, positionPin: nil))
            return
        }
        let snapshot = session.store.snapshot()
        if let visual = snapshot.nodes.first(where: { $0.id == primary }) {
            session.apply(
                SetPinCommand(
                    nodeID: primary,
                    positionPin: Point2D(x: visual.frame.midX, y: visual.frame.midY)
                )
            )
        } else {
            session.apply(SetPinCommand(nodeID: primary, positionPin: .zero))
        }
    }
}
