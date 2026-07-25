import SwiftUI
import SwiftMindCore

@MainActor
final class DocumentSession: ObservableObject {
    /// Core store (not ObservableObject). UI reacts via `revision`.
    @Published private(set) var store: MapStore
    /// Mirrors `store.revision` so SwiftUI can observe mutations on the plain `MapStore`.
    @Published private(set) var revision: UInt64 = 0
    @Published var viewMode: ViewMode = .map

    enum ViewMode: String, CaseIterable, Identifiable {
        case map
        case outline

        var id: String { rawValue }

        var title: String {
            switch self {
            case .map: return "Map"
            case .outline: return "Outline"
            }
        }
    }

    init(map: MindMap) {
        let store = MapStore(map: map)
        self.store = store
        self.revision = store.revision
    }

    func syncFromDocument(_ map: MindMap) {
        store.replaceMap(map)
        publishRevision()
    }

    func exportMap() -> MindMap {
        store.map
    }

    func apply(_ command: any MapCommand) {
        do {
            try store.dispatch(command)
            publishRevision()
        } catch {
            // Present alerts later; for M1 log only.
            print("command failed: \(error)")
        }
    }

    func undo() {
        do {
            try store.undo()
            publishRevision()
        } catch {
            print("undo failed: \(error)")
        }
    }

    func redo() {
        do {
            try store.redo()
            publishRevision()
        } catch {
            print("redo failed: \(error)")
        }
    }

    func select(_ id: NodeID, additive: Bool = false) {
        store.select(id, additive: additive)
        publishRevision()
    }

    var canUndo: Bool { store.canUndo }
    var canRedo: Bool { store.canRedo }

    private func publishRevision() {
        revision = store.revision
        // Ensure views observing `store` also refresh after in-place mutations.
        objectWillChange.send()
    }
}
