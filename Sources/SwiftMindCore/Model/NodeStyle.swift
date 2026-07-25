public struct NodeStyle: Equatable, Sendable, Codable {
    public var fontSize: Double
    public var isBold: Bool
    /// sRGB 0...1
    public var textRed: Double
    public var textGreen: Double
    public var textBlue: Double
    public var fillRed: Double?
    public var fillGreen: Double?
    public var fillBlue: Double?

    public init(
        fontSize: Double = 14,
        isBold: Bool = false,
        textRed: Double = 0,
        textGreen: Double = 0,
        textBlue: Double = 0,
        fillRed: Double? = nil,
        fillGreen: Double? = nil,
        fillBlue: Double? = nil
    ) {
        self.fontSize = fontSize
        self.isBold = isBold
        self.textRed = textRed
        self.textGreen = textGreen
        self.textBlue = textBlue
        self.fillRed = fillRed
        self.fillGreen = fillGreen
        self.fillBlue = fillBlue
    }

    /// Root: confident accent fill + light text (readable in light and dark chrome).
    public static let rootDefault = NodeStyle(
        fontSize: 22,
        isBold: true,
        textRed: 1,
        textGreen: 1,
        textBlue: 1,
        fillRed: 0.18,
        fillGreen: 0.42,
        fillBlue: 0.92
    )

    /// Body nodes: pure black text is treated as theme-adaptive on the canvas.
    public static let `default` = NodeStyle()
}
