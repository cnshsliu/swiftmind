import Foundation
import SwiftMindCore

/// Builds the navigable **My Brain** mind map from registered vault folders.
///
/// Tree shape:
/// ```
/// My Brain
/// ├── Vault Name          (kind=vault)
/// │   ├── Subfolder       (kind=folder)
/// │   │   └── map.html    (kind=map)
/// │   └── other.swiftmind.html
/// └── Another Vault
/// ```
@MainActor
enum BrainMapBuilder {
    static let kindAttr = "sm.kind"
    static let pathAttr = "sm.path"

    enum Kind: String {
        case brain
        case vault
        case folder
        case map
    }

    static func build(library: VaultLibrary) -> MindMap {
        var root = Node(
            id: stableID(path: "my-brain", kind: .brain),
            text: "My Brain",
            attributes: [
                NodeAttribute(name: kindAttr, value: Kind.brain.rawValue),
            ],
            styleName: "important",
            isFolded: false,
            side: .auto,
            children: []
        )

        var children: [Node] = []
        for (index, vaultURL) in library.vaultURLs.enumerated() {
            _ = library.startAccessing(vaultURL)
            let side: NodeSide = index % 2 == 0 ? .left : .right
            var seen = Set<String>()
            let node = makeDirectoryNode(
                url: vaultURL,
                kind: .vault,
                side: side,
                library: library,
                depth: 0,
                seen: &seen
            )
            children.append(node)
        }
        root.children = children

        var map = MindMap(
            id: "m_my_brain",
            title: "My Brain",
            root: root
        )
        // Light registry so inspector can show kind/path if needed.
        map.attributeRegistry = AttributeRegistry(definitions: [
            AttributeDefinition(name: kindAttr, valueType: .string),
            AttributeDefinition(name: pathAttr, valueType: .string),
        ])
        return map
    }

    private static func makeDirectoryNode(
        url: URL,
        kind: Kind,
        side: NodeSide,
        library: VaultLibrary,
        depth: Int,
        seen: inout Set<String>
    ) -> Node {
        let path = url.standardizedFileURL.path
        let name = url.lastPathComponent
        let folded = library.isFolded(path: path)

        var childNodes: [Node] = []
        if !folded {
            childNodes = listChildren(of: url, library: library, depth: depth + 1, seen: &seen)
        }

        let icon: NodeIcon? = {
            switch kind {
            case .vault: return NodeIcon(id: "star") // fallback if no folder icon
            case .folder: return NodeIcon(id: "todo")
            default: return nil
            }
        }()

        return Node(
            id: stableID(path: path, kind: kind),
            text: name,
            icons: icon.map { [$0] } ?? [],
            attributes: [
                NodeAttribute(name: kindAttr, value: kind.rawValue),
                NodeAttribute(name: pathAttr, value: path),
            ],
            isFolded: folded,
            side: side,
            children: childNodes
        )
    }

    private static func listChildren(
        of directory: URL,
        library: VaultLibrary,
        depth: Int,
        seen: inout Set<String>
    ) -> [Node] {
        let canonical = MindMapBundle.canonicalPath(directory)
        guard seen.insert(canonical).inserted else { return [] }
        guard depth <= 16 else { return [] }
        var folders: [Node] = []
        var maps: [Node] = []
        for child in MindMapBundle.children(of: directory) {
            switch child.kind {
            case .folder:
                folders.append(
                    makeDirectoryNode(
                        url: child.url,
                        kind: .folder,
                        side: .auto,
                        library: library,
                        depth: depth,
                        seen: &seen
                    )
                )
            case .map:
                maps.append(makeMapNode(url: child.url, side: .auto))
            }
        }
        return folders + maps
    }

    private static func makeMapNode(url: URL, side: NodeSide) -> Node {
        let path = url.standardizedFileURL.path
        var title = url.lastPathComponent
        if title.hasSuffix(".swiftmind.html") {
            title = String(title.dropLast(".swiftmind.html".count))
        } else if title.hasSuffix(".html") {
            title = String(title.dropLast(".html".count))
        }
        return Node(
            id: stableID(path: path, kind: .map),
            text: title.isEmpty ? url.lastPathComponent : title,
            icons: [NodeIcon(id: "idea")],
            attributes: [
                NodeAttribute(name: kindAttr, value: Kind.map.rawValue),
                NodeAttribute(name: pathAttr, value: path),
            ],
            isFolded: false,
            side: side,
            children: []
        )
    }

    /// Stable IDs so selection/fold survive rebuilds.
    static func stableID(path: String, kind: Kind) -> NodeID {
        NodeID(rawValue: "brain_\(kind.rawValue)_\(path)")
    }

    static func kind(of node: Node) -> Kind? {
        guard let raw = node.attributeValue(named: kindAttr) else { return nil }
        return Kind(rawValue: raw)
    }

    static func path(of node: Node) -> String? {
        node.attributeValue(named: pathAttr)
    }
}
