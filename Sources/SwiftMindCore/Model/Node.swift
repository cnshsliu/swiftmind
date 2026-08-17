public struct Node: Identifiable, Equatable, Sendable, Codable {
    public var id: NodeID
    public var text: String
    public var noteMarkdown: String
    public var links: [NodeLink]
    public var icons: [NodeIcon]
    public var attributes: [NodeAttribute]
    /// Named style key from `MindMap.styleSheet` (optional).
    public var styleName: String?
    /// L1 formula source (optional). The computed value is derived, never stored.
    public var formula: String?
    public var isFolded: Bool
    public var side: NodeSide
    public var style: NodeStyle
    public var positionPin: Point2D?
    public var children: [Node]

    public init(
        id: NodeID = .generate(),
        text: String,
        noteMarkdown: String = "",
        links: [NodeLink] = [],
        icons: [NodeIcon] = [],
        attributes: [NodeAttribute] = [],
        styleName: String? = nil,
        formula: String? = nil,
        isFolded: Bool = false,
        side: NodeSide = .auto,
        style: NodeStyle = .default,
        positionPin: Point2D? = nil,
        children: [Node] = []
    ) {
        self.id = id
        self.text = text
        self.noteMarkdown = noteMarkdown
        self.links = links
        self.icons = icons
        self.attributes = attributes
        self.styleName = styleName
        self.formula = formula
        self.isFolded = isFolded
        self.side = side
        self.style = style
        self.positionPin = positionPin
        self.children = children
    }

    public func attributeValue(named name: String) -> String? {
        attributes.first { $0.name == name }?.value
    }
}
