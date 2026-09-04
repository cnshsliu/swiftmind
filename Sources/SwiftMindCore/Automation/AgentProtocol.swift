import Foundation

/// Shared JSON tree shape for the CLI `read` command and the app bridge's
/// `read` method. When formula results are provided (live session only),
/// each formula node also carries its computed `formulaResult` display text.
public enum AgentProtocol {
    public static func mapJSON(
        for map: MindMap,
        formulaResults: [NodeID: FormulaValue] = [:]
    ) -> [String: Any] {
        [
            "id": map.id,
            "title": map.title,
            "schemaVersion": map.schemaVersion,
            "root": nodeJSON(map.root, formulaResults: formulaResults),
        ]
    }

    private static func nodeJSON(
        _ node: Node,
        formulaResults: [NodeID: FormulaValue]
    ) -> [String: Any] {
        var dict: [String: Any] = [
            "id": node.id.rawValue,
            "text": node.text,
        ]
        if !node.noteMarkdown.isEmpty { dict["note"] = node.noteMarkdown }
        if !node.attributes.isEmpty {
            dict["attributes"] = node.attributes.map { ["name": $0.name, "value": $0.value] }
        }
        if let formula = node.formula {
            dict["formula"] = formula
            if let result = formulaResults[node.id] {
                dict["formulaResult"] = result.displayText
            }
        }
        if node.isFolded { dict["folded"] = true }
        if node.side != .auto { dict["side"] = node.side.rawValue }
        if node.positionPin != nil { dict["pinned"] = true }
        if !node.children.isEmpty {
            dict["children"] = node.children.map { nodeJSON($0, formulaResults: formulaResults) }
        }
        return dict
    }
}
