public struct LayoutConfig: Equatable, Sendable {
    public var horizontalGap: Double = 56
    /// Vertical gap between sibling blocks on the same side.
    public var verticalGap: Double = 28
    public var minNodeWidth: Double = 48
    public var nodeHeight: Double = 32
    public var charWidth: Double = 8
    public var paddingX: Double = 12
    public var iconSlotWidth: Double = 14
    public var badgeReserve: Double = 12

    public init() {}

    public init(
        horizontalGap: Double = 56,
        verticalGap: Double = 28,
        minNodeWidth: Double = 48,
        nodeHeight: Double = 32,
        charWidth: Double = 8,
        paddingX: Double = 12,
        iconSlotWidth: Double = 14,
        badgeReserve: Double = 12
    ) {
        self.horizontalGap = horizontalGap
        self.verticalGap = verticalGap
        self.minNodeWidth = minNodeWidth
        self.nodeHeight = nodeHeight
        self.charWidth = charWidth
        self.paddingX = paddingX
        self.iconSlotWidth = iconSlotWidth
        self.badgeReserve = badgeReserve
    }
}
