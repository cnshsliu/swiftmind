enum HTMLSkin {
    static let readOnlyCSS: String = """
    :root {
      color-scheme: light dark;
      --sm-bg: #f5f5f7;
      --sm-fg: #1d1d1f;
      --sm-muted: #6e6e73;
      --sm-card: #ffffff;
      --sm-border: #e5e5ea;
      --sm-line: #d2d2d7;
      --sm-accent: #0071e3;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --sm-bg: #1c1c1e;
        --sm-fg: #f5f5f7;
        --sm-muted: #98989d;
        --sm-card: #2c2c2e;
        --sm-border: #3a3a3c;
        --sm-line: #48484a;
        --sm-accent: #0a84ff;
      }
    }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
      margin: 0;
      padding: 28px 24px 48px;
      line-height: 1.45;
      color: var(--sm-fg);
      background: var(--sm-bg);
      -webkit-font-smoothing: antialiased;
    }
    .swiftmind-map {
      max-width: 44rem;
      margin: 0 auto;
    }
    .swiftmind-map ul {
      list-style: none;
      margin: 0;
      padding-left: 1.15rem;
      border-left: 2px solid var(--sm-line);
    }
    .swiftmind-map > ul {
      padding-left: 0;
      border-left: none;
    }
    .swiftmind-map li {
      margin: 0.45rem 0;
    }
    .node-title {
      display: inline-block;
      padding: 0.28rem 0.65rem;
      border-radius: 8px;
      background: var(--sm-card);
      border: 1px solid var(--sm-border);
      font-weight: 500;
      letter-spacing: -0.01em;
      box-shadow: 0 1px 2px rgba(0,0,0,0.04);
    }
    .swiftmind-map > ul > li > .node-title {
      font-size: 1.15rem;
      font-weight: 600;
      border-color: color-mix(in srgb, var(--sm-accent) 35%, var(--sm-border));
      box-shadow: 0 1px 3px rgba(0,0,0,0.06);
    }
    .node-note[hidden] {
      display: block !important;
      opacity: 0.82;
      font-size: 0.9em;
      margin: 0.3rem 0 0.35rem 0.55rem;
      white-space: pre-wrap;
      color: var(--sm-muted);
      max-width: 36rem;
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
