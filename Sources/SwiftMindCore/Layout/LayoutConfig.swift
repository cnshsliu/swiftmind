public struct LayoutConfig: Equatable, Sendable {
    public var horizontalGap: Double = 48
    public var verticalGap: Double = 16
    public var minNodeWidth: Double = 48
    public var nodeHeight: Double = 32
    public var charWidth: Double = 8
    public var paddingX: Double = 12
    /// Width reserved per displayed icon (matches canvas `iconSlot`).
    public var iconSlotWidth: Double = 14
    /// Extra horizontal room for note / pin corner badges.
    public var badgeReserve: Double = 12

    public init() {}

    public init(
        horizontalGap: Double = 48,
        verticalGap: Double = 16,
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
