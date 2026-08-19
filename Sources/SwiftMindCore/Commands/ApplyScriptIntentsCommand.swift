/// Applies a script's recorded intents as ONE undoable step.
/// Unknown node ids are skipped (counted in `skippedCount`) — a stale intent
/// never fails the batch.
public final class ApplyScriptIntentsCommand: MapCommand {
    public let name = "ApplyScriptIntents"
    public let intents: [ScriptIntent]

    private struct PriorState {
        var text: String
        var note: String
        var attributes: [NodeAttribute]
        var icons: [NodeIcon]
        var styleName: String?
    }

    private var didCapture = false
    private var prior: [NodeID: PriorState] = [:]

    /// Intents applied / skipped for unknown nodes (valid after execute).
    public private(set) var appliedCount = 0
    public private(set) var skippedCount = 0

    public init(intents: [ScriptIntent]) {
        self.intents = intents
    }

    public func execute(on map: inout MindMap) throws {
        if !didCapture {
            for intent in intents {
                let id = Self.nodeID(of: intent)
                if prior[id] == nil, let node = map.node(id: id) {
                    prior[id] = PriorState(
                        text: node.text,
                        note: node.noteMarkdown,
                        attributes: node.attributes,
                        icons: node.icons,
                        styleName: node.styleName
                    )
                }
            }
            didCapture = true
        }

        var applied = 0
        var skipped = 0
        for intent in intents {
            let id = Self.nodeID(of: intent)
            guard prior[id] != nil else {
                skipped += 1
                continue
            }
            Self.apply(intent, to: &map)
            applied += 1
        }
        appliedCount = applied
        skippedCount = skipped
    }

    public func undo(on map: inout MindMap) throws {
        guard didCapture else { return }
        for (id, state) in prior {
            map.updateNode(id: id) { node in
                node.text = state.text
                node.noteMarkdown = state.note
                node.attributes = state.attributes
                node.icons = state.icons
                node.styleName = state.styleName
            }
        }
    }

    private static func nodeID(of intent: ScriptIntent) -> NodeID {
        switch intent {
        case .setText(let id, _),
             .setNote(let id, _),
             .setAttribute(let id, _, _),
             .addIcon(let id, _),
             .removeIcon(let id, _),
             .setStyleName(let id, _):
            return id
        }
    }

    private static func apply(_ intent: ScriptIntent, to map: inout MindMap) {
        switch intent {
        case .setText(let id, let text):
            map.updateNode(id: id) { $0.text = text }
        case .setNote(let id, let note):
            map.updateNode(id: id) { $0.noteMarkdown = note }
        case .setAttribute(let id, let name, let value):
            if value.isEmpty {
                map.updateNode(id: id) { $0.attributes.removeAll { $0.name == name } }
            } else {
                map.updateNode(id: id) { node in
                    if let index = node.attributes.firstIndex(where: { $0.name == name }) {
                        node.attributes[index].value = value
                    } else {
                        node.attributes.append(NodeAttribute(name: name, value: value))
                    }
                }
                map.attributeRegistry.ensureRegistered(name)
            }
        case .addIcon(let id, let iconID):
            map.updateNode(id: id) { node in
                if !node.icons.contains(where: { $0.id == iconID }) {
                    node.icons.append(NodeIcon(id: iconID))
                }
            }
        case .removeIcon(let id, let iconID):
            map.updateNode(id: id) { $0.icons.removeAll { $0.id == iconID } }
        case .setStyleName(let id, let styleName):
            map.updateNode(id: id) { $0.styleName = styleName }
        }
    }
}
