import Foundation

/// A single declarative mutation proposed by a script. Scripts never touch the
/// map directly — intents are validated and applied as one undoable command batch
/// only after the script finishes cleanly (see `ApplyScriptIntentsCommand`).
public enum ScriptIntent: Equatable, Sendable {
    case setText(NodeID, String)
    case setNote(NodeID, String)
    /// Empty value removes the attribute.
    case setAttribute(NodeID, name: String, value: String)
    case addIcon(NodeID, String)
    case removeIcon(NodeID, String)
    /// nil clears the named style.
    case setStyleName(NodeID, String?)
}

/// Outcome of a script run. `error != nil` means nothing is applied.
public struct ScriptResult: Equatable, Sendable {
    public var intents: [ScriptIntent]
    public var logs: [String]
    public var error: String?

    public init(intents: [ScriptIntent] = [], logs: [String] = [], error: String? = nil) {
        self.intents = intents
        self.logs = logs
        self.error = error
    }

    public var isSuccess: Bool { error == nil }
}

/// Pluggable script engine seam (spec §3.3). Core ships a JavaScriptCore
/// implementation; tests use fakes. Implementations must be self-contained:
/// no network, file, or process access is provided to scripts.
public protocol ScriptRuntime: Sendable {
    /// Runs `source` against the API. Must always return — errors go in
    /// `ScriptResult.error`, never thrown across the boundary.
    func run(source: String, api: any MapScriptAPI) -> ScriptResult
}
