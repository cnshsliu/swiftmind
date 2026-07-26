import SwiftUI
import SwiftMindCore

@MainActor
final class DocumentSession: ObservableObject {
    /// Core store (not ObservableObject). UI reacts via `revision`.
    @Published private(set) var store: MapStore
    /// Mirrors `store.revision` so SwiftUI can observe mutations on the plain `MapStore`.
    @Published private(set) var revision: UInt64 = 0
    @Published var viewMode: ViewMode = .map
    /// Transient chrome message (delete confirmation, command errors).
    @Published private(set) var toast: StatusToast?

    private var toastClearTask: Task<Void, Never>?

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
            announceSuccess(for: command)
        } catch {
            presentError(error)
        }
    }

    /// Apply without success toast (typing, style sliders).
    func applyQuiet(_ command: any MapCommand) {
        do {
            try store.dispatch(command)
            publishRevision()
        } catch {
            presentError(error)
        }
    }

    func undo() {
        do {
            try store.undo()
            publishRevision()
            showToast("Undid last change", kind: .info)
        } catch {
            presentError(error)
        }
    }

    func redo() {
        do {
            try store.redo()
            publishRevision()
            showToast("Redid last change", kind: .info)
        } catch {
            presentError(error)
        }
    }

    func select(_ id: NodeID, additive: Bool = false) {
        store.select(id, additive: additive)
        publishRevision()
    }

    var canUndo: Bool { store.canUndo }
    var canRedo: Bool { store.canRedo }

    func showToast(_ message: String, kind: StatusToast.Kind = .info, duration: TimeInterval = 2.2) {
        toastClearTask?.cancel()
        toast = StatusToast(message: message, kind: kind)
        toastClearTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            if toast?.message == message {
                toast = nil
            }
        }
    }

    func dismissToast() {
        toastClearTask?.cancel()
        toast = nil
    }

    private func announceSuccess(for command: any MapCommand) {
        switch command.name {
        case "DeleteNodes":
            showToast("Deleted · ⌘Z to undo", kind: .success)
        case "MoveNode":
            showToast("Moved node · ⌘Z to undo", kind: .success)
        case "InsertChild", "InsertSibling":
            break // Frequent — no toast (Emil: don't animate/noise keyboard-rate actions)
        default:
            break
        }
    }

    private func presentError(_ error: Error) {
        let message: String
        if let mapError = error as? MapCommandError {
            message = mapError.userFacingMessage
        } else {
            message = error.localizedDescription
        }
        showToast(message, kind: .error, duration: 3.2)
    }

    private func publishRevision() {
        revision = store.revision
        objectWillChange.send()
    }
}

extension MapCommandError {
    var userFacingMessage: String {
        switch self {
        case .nodeNotFound:
            return "That node is no longer available"
        case .cannotDeleteRoot:
            return "Can't delete the central idea"
        case .invalidParent:
            return "Can't move a node into its own branch"
        }
    }
}
