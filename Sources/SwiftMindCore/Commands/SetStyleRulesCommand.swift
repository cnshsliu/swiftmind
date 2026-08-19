public final class SetStyleRulesCommand: MapCommand {
    public let name = "SetStyleRules"
    /// Full replacement list of conditional style rules (map-level).
    public let rules: [ConditionalStyleRule]
    private var didCapture = false
    private var old: [ConditionalStyleRule] = []

    public init(rules: [ConditionalStyleRule]) {
        self.rules = rules
    }

    public func execute(on map: inout MindMap) throws {
        if !didCapture {
            old = map.styleSheet.rules
            didCapture = true
        }
        map.styleSheet.rules = rules
    }

    public func undo(on map: inout MindMap) throws {
        guard didCapture else { return }
        map.styleSheet.rules = old
    }
}
