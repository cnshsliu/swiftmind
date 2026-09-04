import SwiftUI
import SwiftMindCore

@MainActor
final class DocumentSession: ObservableObject {
    public private(set) var store: MapStore
    /// Map structure/content — triggers document dirty sync.
    @Published private(set) var contentRevision: UInt64 = 0
    /// Selection-only — redraw selection without rewriting the document.
    @Published private(set) var selectionRevision: UInt64 = 0
    @Published var viewMode: ViewMode = .map
    @Published private(set) var toast: StatusToast?

    /// True when showing the My Brain vault navigator (not a map file).
    var isBrainMode: Bool = false
    /// Double-click / Return activation (open map or toggle folder in brain mode).
    var onPrimaryActivate: (() -> Void)?
    /// Fired after content mutations (for autosave).
    var onContentChanged: (() -> Void)?

    private var toastClearTask: Task<Void, Never>?

    /// Back-compat for views that observe a single tick.
    var revision: UInt64 { contentRevision &+ selectionRevision }

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
        self.store = MapStore(map: map)
        self.contentRevision = store.contentRevision
        self.selectionRevision = store.selectionRevision
    }

    func syncFromDocument(_ map: MindMap) {
        store.replaceMap(map)
        publishContent()
    }

    func exportMap() -> MindMap {
        store.map
    }

    func apply(_ command: any MapCommand) {
        do {
            try store.dispatch(command)
            publishContent()
            announceSuccess(for: command)
        } catch {
            presentError(error)
        }
    }

    func applyQuiet(_ command: any MapCommand) {
        do {
            try store.dispatch(command)
            publishContent()
        } catch {
            presentError(error)
        }
    }

    /// Bridge path: throws instead of toasting so the caller reports back.
    func applyThrowing(_ command: any MapCommand) throws {
        try store.dispatch(command)
        publishContent()
    }

    func undo() {
        do {
            try store.undo()
            publishContent()
            showToast("Undid last change", kind: .info)
        } catch {
            presentError(error)
        }
    }

    func redo() {
        do {
            try store.redo()
            publishContent()
            showToast("Redid last change", kind: .info)
        } catch {
            presentError(error)
        }
    }

    /// Selection only — does not mark the document dirty or relayout geometry.
    func select(_ id: NodeID, additive: Bool = false) {
        store.select(id, additive: additive)
        selectionRevision = store.selectionRevision
        objectWillChange.send()
    }

    /// Clear focus (Esc / click on blank canvas).
    func clearSelection() {
        store.clearSelection()
        selectionRevision = store.selectionRevision
        objectWillChange.send()
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

    private func publishContent() {
        contentRevision = store.contentRevision
        selectionRevision = store.selectionRevision
        objectWillChange.send()
        onContentChanged?()
    }

    func activatePrimary() {
        onPrimaryActivate?()
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
