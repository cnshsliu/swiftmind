import Foundation

/// L2 declarative bulk action: a single mutation applied to every node matching
/// a filter rule (see `ApplyBulkActionCommand`). No general code — just data.
public enum BulkAction: Equatable, Sendable {
    case setAttribute(name: String, value: String)
    case removeAttribute(name: String)
    case addIcon(String)
    case removeIcon(String)
    /// nil clears the named style.
    case setStyleName(String?)

    /// Applies the action to a node in place. Registry registration is the
    /// command's job (it owns the map).
    public func apply(to node: inout Node) {
        switch self {
        case .setAttribute(let name, let value):
            if let index = node.attributes.firstIndex(where: { $0.name == name }) {
                node.attributes[index].value = value
            } else {
                node.attributes.append(NodeAttribute(name: name, value: value))
            }
        case .removeAttribute(let name):
            node.attributes.removeAll { $0.name == name }
        case .addIcon(let iconID):
            if !node.icons.contains(where: { $0.id == iconID }) {
                node.icons.append(NodeIcon(id: iconID))
            }
        case .removeIcon(let iconID):
            node.icons.removeAll { $0.id == iconID }
        case .setStyleName(let styleName):
            node.styleName = styleName
        }
    }
}
