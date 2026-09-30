/// Built-in node icon identifier (not AppKit/CoreServices `IconRef`).
public struct NodeIcon: Equatable, Sendable, Codable, Hashable, Identifiable {
    public var id: String

    public init(id: String) {
        self.id = id
    }

    public static func builtin(_ id: String) -> NodeIcon {
        NodeIcon(id: id)
    }

    /// One catalog category (name + icons in display order).
    public struct Category: Equatable, Sendable {
        public let name: String
        public let icons: [NodeIcon]
        public init(name: String, icons: [NodeIcon]) {
            self.name = name
            self.icons = icons
        }
    }

    /// The full catalog as (category, id, SF Symbol) rows — the single source
    /// for `categories`, `catalog`, and `sfSymbolNames` (they can never drift).
    private static let table: [(category: String, id: String, symbol: String)] = [
        // Status
        ("Status", "check", "checkmark.circle.fill"),
        ("Status", "todo", "circle"),
        ("Status", "doing", "circle.lefthalf.fill"),
        ("Status", "done", "checkmark.square.fill"),
        ("Status", "blocked", "xmark.octagon.fill"),
        ("Status", "warning", "exclamationmark.triangle.fill"),
        ("Status", "important", "exclamationmark.circle.fill"),
        ("Status", "question", "questionmark.circle.fill"),
        ("Status", "info", "info.circle.fill"),
        ("Status", "pause", "pause.circle.fill"),
        ("Status", "up", "arrow.up.circle.fill"),
        ("Status", "down", "arrow.down.circle.fill"),
        // Flags & marks
        ("Marks", "flag", "flag.fill"),
        ("Marks", "finish", "flag.checkered"),
        ("Marks", "star", "star.fill"),
        ("Marks", "heart", "heart.fill"),
        ("Marks", "bookmark", "bookmark.fill"),
        ("Marks", "pin", "pin.fill"),
        ("Marks", "tag", "tag.fill"),
        ("Marks", "bell", "bell.fill"),
        ("Marks", "award", "award.fill"),
        ("Marks", "crown", "crown.fill"),
        ("Marks", "shield", "shield.fill"),
        ("Marks", "rosette", "rosette"),
        // Thinking
        ("Thinking", "idea", "lightbulb.fill"),
        ("Thinking", "sparkles", "sparkles"),
        ("Thinking", "puzzle", "puzzlepiece.fill"),
        ("Thinking", "brain", "brain"),
        ("Thinking", "target", "scope"),
        ("Thinking", "search", "magnifyingglass"),
        ("Thinking", "eye", "eye.fill"),
        ("Thinking", "book", "book.fill"),
        ("Thinking", "wand", "wand.and.stars"),
        ("Thinking", "question-bubble", "questionmark.bubble.fill"),
        ("Thinking", "note", "note.text"),
        ("Thinking", "chat-bubble", "text.bubble.fill"),
        // People & communication
        ("People", "person", "person.fill"),
        ("People", "people", "person.2.fill"),
        ("People", "group", "person.3.fill"),
        ("People", "chat", "bubble.left.fill"),
        ("People", "reply", "bubble.right.fill"),
        ("People", "mail", "envelope.fill"),
        ("People", "phone", "phone.fill"),
        ("People", "video", "video.fill"),
        ("People", "mic", "mic.fill"),
        ("People", "share", "square.and.arrow.up"),
        ("People", "avatar", "person.crop.circle.fill"),
        ("People", "export", "arrow.uturn.left"),
        // Work
        ("Work", "briefcase", "briefcase.fill"),
        ("Work", "doc", "doc.fill"),
        ("Work", "docs", "doc.on.doc.fill"),
        ("Work", "folder", "folder.fill"),
        ("Work", "clipboard", "clipboard.fill"),
        ("Work", "calendar", "calendar"),
        ("Work", "clock", "clock.fill"),
        ("Work", "timer", "timer"),
        ("Work", "key", "key.fill"),
        ("Work", "lock", "lock.fill"),
        ("Work", "wrench", "wrench.fill"),
        ("Work", "gear", "gearshape.fill"),
        // Nature
        ("Nature", "sun", "sun.max.fill"),
        ("Nature", "moon", "moon.fill"),
        ("Nature", "cloud", "cloud.fill"),
        ("Nature", "rain", "cloud.rain.fill"),
        ("Nature", "snow", "snowflake"),
        ("Nature", "leaf", "leaf.fill"),
        ("Nature", "tree", "tree.fill"),
        ("Nature", "drop", "drop.fill"),
        ("Nature", "flame", "flame.fill"),
        ("Nature", "wind", "wind"),
        ("Nature", "globe", "globe"),
        ("Nature", "house", "house.fill"),
        // Objects & places
        ("Objects", "cart", "cart.fill"),
        ("Objects", "gift", "gift.fill"),
        ("Objects", "plane", "airplane"),
        ("Objects", "car", "car.fill"),
        ("Objects", "bike", "bicycle"),
        ("Objects", "mappin", "mappin.circle.fill"),
        ("Objects", "camera", "camera.fill"),
        ("Objects", "music", "music.note"),
        ("Objects", "play", "play.fill"),
        ("Objects", "tv", "tv.fill"),
        ("Objects", "trash", "trash.fill"),
        ("Objects", "wallet", "creditcard.fill"),
        // Symbols
        ("Symbols", "plus", "plus.circle.fill"),
        ("Symbols", "minus", "minus.circle.fill"),
        ("Symbols", "xmark", "xmark.circle.fill"),
        ("Symbols", "percent", "percent"),
        ("Symbols", "dollar", "dollarsign.circle.fill"),
        ("Symbols", "yen", "yensign.circle.fill"),
        ("Symbols", "at", "at"),
        ("Symbols", "hash", "number"),
        ("Symbols", "infinity", "infinity"),
        ("Symbols", "link", "link"),
        ("Symbols", "keyboard", "keyboard"),
        ("Symbols", "funnel", "line.3.horizontal.decrease.circle.fill"),
    ]

    /// Categorized catalog in display order.
    public static let categories: [Category] = {
        var order: [String] = []
        var groups: [String: [NodeIcon]] = [:]
        for row in table {
            if groups[row.category] == nil { order.append(row.category) }
            groups[row.category, default: []].append(NodeIcon(id: row.id))
        }
        return order.map { Category(name: $0, icons: groups[$0] ?? []) }
    }()

    /// Flat catalog (all categories).
    public static let catalog: [NodeIcon] = table.map { NodeIcon(id: $0.id) }

    /// Maps catalog id → SF Symbol name for the Mac app (Core stays UI-free).
    public static let sfSymbolNames: [String: String] = {
        Dictionary(table.map { ($0.id, $0.symbol) }, uniquingKeysWith: { a, _ in a })
    }()
}
