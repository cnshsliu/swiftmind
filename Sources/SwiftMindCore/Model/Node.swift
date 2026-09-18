import Foundation

public struct Node: Identifiable, Equatable, Sendable, Codable {
    public var id: NodeID
    public var text: String
    public var noteMarkdown: String
    /// Opaque PencilKit PKDrawing payload (node content IS a sketch). nil = normal text node.
    /// Normalized so trimmed content starts at the trim-padding origin. Core never decodes it.
    public var sketch: Data?
    /// Trimmed content width/height (incl. trim padding) in board points; nil until content exists.
    public var sketchWidth: Double?
    public var sketchHeight: Double?
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
    /// Show the note as a rendered markdown card on the canvas (persisted).
    public var isNoteExpanded: Bool
    public var children: [Node]

    public init(
        id: NodeID = .generate(),
        text: String,
        noteMarkdown: String = "",
        sketch: Data? = nil,
        sketchWidth: Double? = nil,
        sketchHeight: Double? = nil,
        links: [NodeLink] = [],
        icons: [NodeIcon] = [],
        attributes: [NodeAttribute] = [],
        styleName: String? = nil,
        formula: String? = nil,
        isFolded: Bool = false,
        side: NodeSide = .auto,
        style: NodeStyle = .default,
        positionPin: Point2D? = nil,
        isNoteExpanded: Bool = false,
        children: [Node] = []
    ) {
        self.id = id
        self.text = text
        self.noteMarkdown = noteMarkdown
        self.sketch = sketch
        self.sketchWidth = sketchWidth
        self.sketchHeight = sketchHeight
        self.links = links
        self.icons = icons
        self.attributes = attributes
        self.styleName = styleName
        self.formula = formula
        self.isFolded = isFolded
        self.side = side
        self.style = style
        self.positionPin = positionPin
        self.isNoteExpanded = isNoteExpanded
        self.children = children
    }

    public func attributeValue(named name: String) -> String? {
        attributes.first { $0.name == name }?.value
    }
}
