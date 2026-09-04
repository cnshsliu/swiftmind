/// A rendered piece of a markdown note document. The segmenter splits raw
/// markdown into text, math, and standalone-image segments so views can
/// render each kind with the right machinery (SwiftUI markdown for text,
/// the LaTeX renderer for math, `NSImage` for embedded images).
public enum MarkdownSegment: Equatable, Sendable {
    /// Literal markdown text (may contain inline markdown the view parses).
    case text(String)
    /// LaTeX source without delimiters. `inline` is `$...$`, block is `$$...$$`.
    case math(inline: Bool, latex: String)
    /// A standalone-line markdown image `![alt](url)`. The url is either an
    /// http(s) URL (never fetched — rendered as a placeholder) or a `data:`
    /// URI (decoded locally).
    case image(alt: String, urlString: String)
}
