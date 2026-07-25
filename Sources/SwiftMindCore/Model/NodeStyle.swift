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

    public static let rootDefault = NodeStyle(fontSize: 22, isBold: true)
    public static let `default` = NodeStyle()
}
