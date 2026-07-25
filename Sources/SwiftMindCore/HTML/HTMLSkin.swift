enum HTMLSkin {
    static let readOnlyCSS: String = """
    body { font-family: -apple-system, system-ui, sans-serif; margin: 24px; }
    .swiftmind-map ul { list-style: none; padding-left: 1.25rem; border-left: 2px solid #ccc; }
    .swiftmind-map li { margin: 0.35rem 0; }
    .node-title { padding: 0.15rem 0.4rem; border-radius: 6px; }
    """

    static func headFragment(includeSkin: Bool) -> String {
        guard includeSkin else { return "" }
        return "<style>\n\(readOnlyCSS)\n</style>\n"
    }
}
