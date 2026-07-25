/// Built-in node icon identifier (not AppKit/CoreServices `IconRef`).
public struct NodeIcon: Equatable, Sendable, Codable, Hashable, Identifiable {
    public var id: String

    public init(id: String) {
        self.id = id
    }

    public static func builtin(_ id: String) -> NodeIcon {
        NodeIcon(id: id)
    }

    /// Small fixed catalog for the product (SF Symbol names used by Mac UI).
    public static let catalog: [NodeIcon] = [
        NodeIcon(id: "check"),
        NodeIcon(id: "flag"),
        NodeIcon(id: "star"),
        NodeIcon(id: "warning"),
        NodeIcon(id: "idea"),
        NodeIcon(id: "question"),
        NodeIcon(id: "important"),
        NodeIcon(id: "todo"),
    ]

    /// Maps catalog id → SF Symbol name for the Mac app (Core stays UI-free).
    public static let sfSymbolNames: [String: String] = [
        "check": "checkmark.circle.fill",
        "flag": "flag.fill",
        "star": "star.fill",
        "warning": "exclamationmark.triangle.fill",
        "idea": "lightbulb.fill",
        "question": "questionmark.circle.fill",
        "important": "exclamationmark.circle.fill",
        "todo": "circle",
    ]
}
