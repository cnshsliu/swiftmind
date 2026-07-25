enum HTMLSkin {
    static let readOnlyCSS: String = """
    body {
      font-family: -apple-system, system-ui, sans-serif;
      margin: 24px;
      line-height: 1.45;
      color: #1d1d1f;
      background: #fafafa;
    }
    .swiftmind-map {
      max-width: 48rem;
    }
    .swiftmind-map ul {
      list-style: none;
      margin: 0;
      padding-left: 1.25rem;
      border-left: 2px solid #d0d0d5;
    }
    .swiftmind-map > ul {
      padding-left: 0;
      border-left: none;
    }
    .swiftmind-map li {
      margin: 0.4rem 0;
    }
    .node-title {
      display: inline-block;
      padding: 0.2rem 0.5rem;
      border-radius: 6px;
      background: #fff;
      border: 1px solid #e5e5ea;
      font-weight: 500;
    }
    /* Share/view skin: reveal notes that stay hidden for app parse. */
    .node-note[hidden] {
      display: block !important;
      opacity: 0.75;
      font-size: 0.9em;
      margin: 0.25rem 0 0.25rem 0.5rem;
      white-space: pre-wrap;
      color: #3a3a3c;
    }
    .node-links[hidden] {
      display: none !important;
    }
    """

    static func headFragment(includeSkin: Bool) -> String {
        guard includeSkin else { return "" }
        return "<style>\n\(readOnlyCSS)\n</style>\n"
    }
}
