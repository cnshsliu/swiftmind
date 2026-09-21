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
    /// Extra node height when a formula is set, so the result can sit under the title.
    public var formulaBadgeHeight: Double = 16
    /// Fixed width of an expanded note card (spec 2026-09-04).
    public var expandedNoteWidth: Double = 360
    /// Estimated height per markdown line in an expanded card (incl. the virtual H1 line).
    public var expandedNoteLineHeight: Double = 20
    /// Expanded cards never grow taller than this; the view scrolls overflow.
    public var expandedNoteMaxHeight: Double = 400
    /// Whitespace kept around trimmed sketch strokes (board points).
    public var sketchTrimPadding: Double = 8
    /// Lower clamp for a trimmed sketch board (tiny content still reads as a node).
    public var sketchMinSize: Double = 40
    /// Upper clamp for a sketch board (runaway drawings never explode the layout).
    public var sketchMaxSize: Double = 1000
    /// Optional title strip above a sketch board.
    public var sketchTitleLineHeight: Double = 20
    /// Display box (points) for inline media: sketch boards scale to fit inside
    /// it, and expanded-note height estimates count one image as one
    /// `mediaMaxSize` row. Driven by the app's media-size setting; still
    /// clamped by `sketchMaxSize` as a hard ceiling.
    public var mediaMaxSize: Double = 160

    public init() {}

    public init(
        horizontalGap: Double = 56,
        verticalGap: Double = 28,
        minNodeWidth: Double = 48,
        nodeHeight: Double = 32,
        charWidth: Double = 8,
        paddingX: Double = 12,
        iconSlotWidth: Double = 14,
        badgeReserve: Double = 12,
        formulaBadgeHeight: Double = 16,
        expandedNoteWidth: Double = 360,
        expandedNoteLineHeight: Double = 20,
        expandedNoteMaxHeight: Double = 400,
        sketchTrimPadding: Double = 8,
        sketchMinSize: Double = 40,
        sketchMaxSize: Double = 1000,
        sketchTitleLineHeight: Double = 20,
        mediaMaxSize: Double = 160
    ) {
        self.horizontalGap = horizontalGap
        self.verticalGap = verticalGap
        self.minNodeWidth = minNodeWidth
        self.nodeHeight = nodeHeight
        self.charWidth = charWidth
        self.paddingX = paddingX
        self.iconSlotWidth = iconSlotWidth
        self.badgeReserve = badgeReserve
        self.formulaBadgeHeight = formulaBadgeHeight
        self.expandedNoteWidth = expandedNoteWidth
        self.expandedNoteLineHeight = expandedNoteLineHeight
        self.expandedNoteMaxHeight = expandedNoteMaxHeight
        self.sketchTrimPadding = sketchTrimPadding
        self.sketchMinSize = sketchMinSize
        self.sketchMaxSize = sketchMaxSize
        self.sketchTitleLineHeight = sketchTitleLineHeight
        self.mediaMaxSize = mediaMaxSize
    }
}
