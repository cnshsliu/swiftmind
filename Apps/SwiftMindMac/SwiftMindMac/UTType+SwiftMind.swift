import UniformTypeIdentifiers

extension UTType {
    static var swiftmindHTML: UTType {
        UTType(exportedAs: "app.swiftmind.html")
    }

    /// Private clipboard flavor: a JSON-encoded `[Node]` subtree.
    static var swiftmindNode: UTType {
        UTType(exportedAs: "app.swiftmind.node")
    }
}
