public struct Rect2D: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public func union(_ other: Rect2D) -> Rect2D {
        let minX = min(x, other.x)
        let minY = min(y, other.y)
        let maxX = max(x + width, other.x + other.width)
        let maxY = max(y + height, other.y + other.height)
        return Rect2D(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Positive values shrink; negative values expand.
    public func inset(by amount: Double) -> Rect2D {
        Rect2D(
            x: x + amount,
            y: y + amount,
            width: width - amount * 2,
            height: height - amount * 2
        )
    }
}

public struct NodeVisual: Equatable, Sendable, Identifiable {
    public var id: NodeID
    public var text: String
    public var frame: Rect2D
    public var style: NodeStyle
    public var depth: Int
    public var side: NodeSide
    public var isFolded: Bool
    public var isSelected: Bool
    /// True when the source node has non-empty note markdown (canvas badge).
    public var hasNote: Bool
    /// Icon catalog ids for canvas badges (order matches node.icons).
    public var iconIDs: [String]
    /// True when the source node has a position pin.
    public var isPinned: Bool
    /// True when the active filter is in highlight mode and this node matches.
    public var isHighlighted: Bool
    /// True when the source node renders its note as a markdown card.
    public var isNoteExpanded: Bool

    public init(
        id: NodeID,
        text: String,
        frame: Rect2D,
        style: NodeStyle,
        depth: Int,
        side: NodeSide,
        isFolded: Bool,
        isSelected: Bool,
        hasNote: Bool = false,
        iconIDs: [String] = [],
        isPinned: Bool = false,
        isHighlighted: Bool = false,
        isNoteExpanded: Bool = false
    ) {
        self.id = id
        self.text = text
        self.frame = frame
        self.style = style
        self.depth = depth
        self.side = side
        self.isFolded = isFolded
        self.isSelected = isSelected
        self.hasNote = hasNote
        self.iconIDs = iconIDs
        self.isPinned = isPinned
        self.isHighlighted = isHighlighted
        self.isNoteExpanded = isNoteExpanded
    }
}

public struct EdgeVisual: Equatable, Sendable, Identifiable {
    public var from: NodeID
    public var to: NodeID
    public var fromPoint: Point2D
    public var toPoint: Point2D

    public var id: String { from.rawValue + "->" + to.rawValue }

    public init(from: NodeID, to: NodeID, fromPoint: Point2D, toPoint: Point2D) {
        self.from = from
        self.to = to
        self.fromPoint = fromPoint
        self.toPoint = toPoint
    }
}

public struct MapSnapshot: Equatable, Sendable {
    public var nodes: [NodeVisual]
    public var edges: [EdgeVisual]
    public var bounds: Rect2D

    public init(nodes: [NodeVisual], edges: [EdgeVisual], bounds: Rect2D) {
        self.nodes = nodes
        self.edges = edges
        self.bounds = bounds
    }

    /// Cheap selection overlay — does not recompute geometry.
    public func applying(selection: SelectionState) -> MapSnapshot {
        let selected = selection.selectedIDs
        let updated = nodes.map { node in
            var copy = node
            copy.isSelected = selected.contains(node.id)
            return copy
        }
        return MapSnapshot(nodes: updated, edges: edges, bounds: bounds)
    }
}
