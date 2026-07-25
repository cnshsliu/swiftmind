public struct Node: Identifiable, Equatable, Sendable, Codable {
    public var id: NodeID
    public var text: String
    public var noteMarkdown: String
    public var links: [NodeLink]
    public var icons: [IconRef]
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
        icons: [IconRef] = [],
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
        self.isFolded = isFolded
        self.side = side
        self.style = style
        self.positionPin = positionPin
        self.children = children
    }
}
