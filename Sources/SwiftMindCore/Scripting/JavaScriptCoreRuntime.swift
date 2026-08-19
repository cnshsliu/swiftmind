import Foundation
import JavaScriptCore

/// L3 script engine on JavaScriptCore (system framework — no deps, App-Sandbox
/// safe, portable to iOS later). Sandbox by construction: the JSContext gets no
/// bridges except the narrow `mindmap` API object, so scripts have no network,
/// file, or process access. Mutation is possible only via recorded intents.
///
/// Results: intents and logs accumulate in the `MapScriptContext` (the API);
/// the returned `ScriptResult` carries only the error (if any). Callers must
/// gate intent application on `error == nil`.
public final class JavaScriptCoreRuntime: ScriptRuntime {
    public init() {}

    public func run(source: String, api: any MapScriptAPI) -> ScriptResult {
        guard let context = JSContext() else {
            return ScriptResult(error: "failed to create JSContext")
        }

        var error: String?
        context.exceptionHandler = { _, exception in
            error = exception?.toString() ?? "unknown script error"
        }

        installAPI(in: context, api: api)
        context.evaluateScript(source)

        return ScriptResult(error: error)
    }

    /// Runs with a wall-clock timeout. On timeout the context is abandoned
    /// (its queue may linger — documented limitation) and an error is returned;
    /// intents recorded by the runaway script must be discarded by the caller.
    public func run(source: String, api: any MapScriptAPI, timeout: TimeInterval) -> ScriptResult {
        let box = ResultBox()
        let queue = DispatchQueue(label: "app.swiftmind.scriptruntime")
        queue.async {
            box.result = self.run(source: source, api: api)
            box.semaphore.signal()
        }
        if box.semaphore.wait(timeout: .now() + timeout) == .timedOut {
            return ScriptResult(error: "script timed out after \(Int(timeout))s")
        }
        return box.result ?? ScriptResult(error: "script did not produce a result")
    }

    // MARK: - API bridge

    private func installAPI(in context: JSContext, api: any MapScriptAPI) {
        let mindmap = JSValue(newObjectIn: context)!

        let title: @convention(block) () -> String = { api.mapTitle }
        mindmap.setValue(title, forProperty: "title")

        let rootId: @convention(block) () -> String = { api.rootID.rawValue }
        mindmap.setValue(rootId, forProperty: "rootId")

        let node: @convention(block) (String) -> Any? = { raw in
            guard let snapshot = api.nodeSnapshot(id: NodeID(rawValue: raw)) else { return NSNull() }
            return [
                "id": snapshot.id.rawValue,
                "text": snapshot.text,
                "note": snapshot.note,
                "attrs": snapshot.attributes,
                "icons": snapshot.icons,
            ] as [String: Any]
        }
        mindmap.setValue(node, forProperty: "node")

        let children: @convention(block) (String) -> [String] = { raw in
            api.childIDs(of: NodeID(rawValue: raw)).map(\.rawValue)
        }
        mindmap.setValue(children, forProperty: "children")

        let find: @convention(block) (String) -> [String] = { query in
            api.find(query).map(\.rawValue)
        }
        mindmap.setValue(find, forProperty: "find")

        let setText: @convention(block) (String, String) -> Void = { raw, text in
            api.record(.setText(NodeID(rawValue: raw), text))
        }
        mindmap.setValue(setText, forProperty: "setText")

        let setNote: @convention(block) (String, String) -> Void = { raw, note in
            api.record(.setNote(NodeID(rawValue: raw), note))
        }
        mindmap.setValue(setNote, forProperty: "setNote")

        let setAttr: @convention(block) (String, String, String) -> Void = { raw, name, value in
            api.record(.setAttribute(NodeID(rawValue: raw), name: name, value: value))
        }
        mindmap.setValue(setAttr, forProperty: "setAttr")

        let addIcon: @convention(block) (String, String) -> Void = { raw, icon in
            api.record(.addIcon(NodeID(rawValue: raw), icon))
        }
        mindmap.setValue(addIcon, forProperty: "addIcon")

        let removeIcon: @convention(block) (String, String) -> Void = { raw, icon in
            api.record(.removeIcon(NodeID(rawValue: raw), icon))
        }
        mindmap.setValue(removeIcon, forProperty: "removeIcon")

        let setStyle: @convention(block) (String, String) -> Void = { raw, style in
            api.record(.setStyleName(NodeID(rawValue: raw), style.isEmpty ? nil : style))
        }
        mindmap.setValue(setStyle, forProperty: "setStyle")

        let log: @convention(block) (String) -> Void = { message in
            api.log(message)
        }
        mindmap.setValue(log, forProperty: "log")

        context.setObject(mindmap, forKeyedSubscript: "mindmap" as NSString)
    }

    /// Sendable box for handoff across the timeout queue (single writer, single reader).
    private final class ResultBox: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        var result: ScriptResult?
    }
}
