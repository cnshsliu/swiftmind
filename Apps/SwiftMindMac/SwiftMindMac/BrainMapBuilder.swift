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
            let side: NodeSide = index % 2 == 0 ? .right : .left
            let node = makeDirectoryNode(
                url: vaultURL,
                kind: .vault,
                side: side,
                library: library,
                depth: 0
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
        depth: Int
    ) -> Node {
        let path = url.standardizedFileURL.path
        let name = url.lastPathComponent
        let folded = library.isFolded(path: path)

        var childNodes: [Node] = []
        if !folded {
            childNodes = listChildren(of: url, library: library, depth: depth + 1)
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

    private static func listChildren(of directory: URL, library: VaultLibrary, depth: Int) -> [Node] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey, .nameKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let sorted = contents.sorted {
            $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
        }

        var folders: [Node] = []
        var maps: [Node] = []

        for item in sorted {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: item.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                // Skip deep stacks beyond a reasonable depth for layout (still navigable via fold).
                folders.append(
                    makeDirectoryNode(
                        url: item,
                        kind: .folder,
                        side: .auto,
                        library: library,
                        depth: depth
                    )
                )
            } else if VaultLibrary.isMindMapFile(item) {
                maps.append(makeMapNode(url: item, side: .auto))
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
        let digest = path.utf8.reduce(UInt64(5381)) { ($0 &<< 5) &+ $0 &+ UInt64($1) }
        return NodeID(rawValue: "brain_\(kind.rawValue)_\(String(digest, radix: 16))")
    }

    static func kind(of node: Node) -> Kind? {
        guard let raw = node.attributeValue(named: kindAttr) else { return nil }
        return Kind(rawValue: raw)
    }

    static func path(of node: Node) -> String? {
        node.attributeValue(named: pathAttr)
    }
}
