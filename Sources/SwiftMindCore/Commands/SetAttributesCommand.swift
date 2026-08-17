public final class SetAttributesCommand: MapCommand {
    public let name = "SetAttributes"
    public let nodeID: NodeID
    public let attributes: [NodeAttribute]
    private var old: [NodeAttribute]?

    public init(nodeID: NodeID, attributes: [NodeAttribute]) {
        self.nodeID = nodeID
        self.attributes = attributes
    }

    public func execute(on map: inout MindMap) throws {
        guard let node = map.node(id: nodeID) else { throw MapCommandError.nodeNotFound(nodeID) }
        if old == nil { old = node.attributes }
        for attr in attributes {
            map.attributeRegistry.ensureRegistered(attr.name)
        }
        guard map.updateNode(id: nodeID, { $0.attributes = attributes }) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
    }

    public func undo(on map: inout MindMap) throws {
        guard let old else { throw MapCommandError.nodeNotFound(nodeID) }
        guard map.updateNode(id: nodeID, { $0.attributes = old }) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
    }
}

public final class UpsertAttributeCommand: MapCommand {
    public let name = "UpsertAttribute"
    public let nodeID: NodeID
    public let attribute: NodeAttribute
    private var oldAttributes: [NodeAttribute]?

    public init(nodeID: NodeID, attribute: NodeAttribute) {
        self.nodeID = nodeID
        self.attribute = attribute
    }

    public func execute(on map: inout MindMap) throws {
        guard let node = map.node(id: nodeID) else { throw MapCommandError.nodeNotFound(nodeID) }
        if oldAttributes == nil { oldAttributes = node.attributes }
        map.attributeRegistry.ensureRegistered(attribute.name)
        var next = node.attributes.filter { $0.name != attribute.name }
        next.append(attribute)
        next.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard map.updateNode(id: nodeID, { $0.attributes = next }) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
    }

    public func undo(on map: inout MindMap) throws {
        guard let oldAttributes else { throw MapCommandError.nodeNotFound(nodeID) }
        guard map.updateNode(id: nodeID, { $0.attributes = oldAttributes }) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
    }
}

public final class SetFilterCommand: MapCommand {
    public let name = "SetFilter"
    public let filter: MapFilter?
    private var old: MapFilter?
    private var captured = false

    public init(filter: MapFilter?) {
        self.filter = filter
    }

    public func execute(on map: inout MindMap) throws {
        if !captured {
            old = map.activeFilter
            captured = true
        }
        map.activeFilter = filter
    }

    public func undo(on map: inout MindMap) throws {
        map.activeFilter = old
    }
}

public final class SetStyleNameCommand: MapCommand {
    public let name = "SetStyleName"
    public let nodeID: NodeID
    public let styleName: String?
    private var old: String??

    public init(nodeID: NodeID, styleName: String?) {
        self.nodeID = nodeID
        self.styleName = styleName
    }

    public func execute(on map: inout MindMap) throws {
        guard let node = map.node(id: nodeID) else { throw MapCommandError.nodeNotFound(nodeID) }
        if old == nil { old = .some(node.styleName) }
        guard map.updateNode(id: nodeID, { $0.styleName = styleName }) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
    }

    public func undo(on map: inout MindMap) throws {
        guard let old else { throw MapCommandError.nodeNotFound(nodeID) }
        guard map.updateNode(id: nodeID, { $0.styleName = old }) else {
            throw MapCommandError.nodeNotFound(nodeID)
        }
    }
}

public final class AddBookmarkCommand: MapCommand {
    public let name = "AddBookmark"
    public let bookmark: Bookmark
    private var didAdd = false

    public init(bookmark: Bookmark) {
        self.bookmark = bookmark
    }

    public func execute(on map: inout MindMap) throws {
        guard map.node(id: bookmark.nodeID) != nil else {
            throw MapCommandError.nodeNotFound(bookmark.nodeID)
        }
        map.bookmarks.removeAll { $0.id == bookmark.id || $0.nodeID == bookmark.nodeID }
        map.bookmarks.append(bookmark)
        didAdd = true
    }

    public func undo(on map: inout MindMap) throws {
        guard didAdd else { return }
        map.bookmarks.removeAll { $0.id == bookmark.id }
    }
}

public final class RemoveBookmarkCommand: MapCommand {
    public let name = "RemoveBookmark"
    public let bookmarkID: String
    private var removed: Bookmark?

    public init(bookmarkID: String) {
        self.bookmarkID = bookmarkID
    }

    public func execute(on map: inout MindMap) throws {
        removed = map.bookmarks.first { $0.id == bookmarkID }
        map.bookmarks.removeAll { $0.id == bookmarkID }
    }

    public func undo(on map: inout MindMap) throws {
        if let removed {
            map.bookmarks.append(removed)
        }
    }
}
