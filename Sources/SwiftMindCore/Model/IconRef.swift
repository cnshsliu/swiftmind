public struct IconRef: Equatable, Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public init(id: String) { self.id = id }
    public static func builtin(_ id: String) -> IconRef { IconRef(id: id) }
    public static let catalog: [IconRef] = [
        IconRef(id: "check"),
        IconRef(id: "flag"),
        IconRef(id: "star"),
        IconRef(id: "warning"),
        IconRef(id: "idea"),
        IconRef(id: "question"),
        IconRef(id: "important"),
        IconRef(id: "todo"),
    ]
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
