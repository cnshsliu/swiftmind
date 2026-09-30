import Foundation

/// Replaces the map's named-style sheet entries (custom styles defined from
/// the inspector's "Save as Style"). Full-state replace, one undo step.
public final class SetNamedStylesCommand: MapCommand {
    public let name = "SetNamedStyles"
    public let styles: [String: NodeStyle]
    private var oldStyles: [String: NodeStyle] = [:]

    public init(styles: [String: NodeStyle]) {
        self.styles = styles
    }

    public func execute(on map: inout MindMap) throws {
        oldStyles = map.styleSheet.styles
        map.styleSheet.styles = styles
    }

    public func undo(on map: inout MindMap) throws {
        map.styleSheet.styles = oldStyles
    }
}
