public struct LayoutConfig: Equatable, Sendable {
    public var horizontalGap: Double = 48
    public var verticalGap: Double = 16
    public var minNodeWidth: Double = 48
    public var nodeHeight: Double = 32
    public var charWidth: Double = 8
    public var paddingX: Double = 12

    public init() {}

    public init(
        horizontalGap: Double = 48,
        verticalGap: Double = 16,
        minNodeWidth: Double = 48,
        nodeHeight: Double = 32,
        charWidth: Double = 8,
        paddingX: Double = 12
    ) {
        self.horizontalGap = horizontalGap
        self.verticalGap = verticalGap
        self.minNodeWidth = minNodeWidth
        self.nodeHeight = nodeHeight
        self.charWidth = charWidth
        self.paddingX = paddingX
    }
}
