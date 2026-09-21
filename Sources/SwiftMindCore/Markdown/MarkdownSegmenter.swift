/// Splits markdown into text / math / image segments with a single
/// left-to-right scan. Pure string logic (core stays UI-free).
///
/// Delimiter rules are deliberately conservative so ordinary prose with
/// dollar amounts never turns into math:
/// - Inline `$...$`: the opening `$` must be preceded by start-of-string,
///   whitespace, or one of `([{>-~`, and followed by a non-space, non-`$`
///   character. The closing `$` must be preceded by a non-space character
///   and followed by end-of-string, whitespace, or one of `)],.;:!?`.
///   The content may not contain a newline or `$`.
/// - Block `$$...$$` may span lines; an unmatched `$$` stays literal.
/// - `$` inside fenced code blocks (``` / ~~~) and inline code spans is
///   never math. `\$` is a literal dollar (the markdown parser unwraps it).
public enum MarkdownSegmenter {
    public static func segments(in markdown: String) -> [MarkdownSegment] {
        var output: [MarkdownSegment] = []
        let chars = Array(markdown)
        let n = chars.count
        var i = 0
        var text = ""
        var fence: String? = nil
        // lineStart + col only matter for fence detection: a fence opens on a
        // line with ≤3 leading whitespace characters. col < 0 means "not at
        // the head of a line" (mid-line content already consumed).
        var lineStart = true
        var col = 0

        func flushText() {
            guard !text.isEmpty else { return }
            appendTextSegments(text, to: &output)
            text = ""
        }

        while i < n {
            let c = chars[i]

            if let marker = fence {
                // Inside a fence everything is verbatim until a closing
                // fence line (marker + optional trailing whitespace).
                if lineStart, col <= 3, c == Character(String(marker.first!)) {
                    let run = String(chars[i..<min(i + 3, n)])
                    var j = i + 3
                    if run == marker {
                        while j < n, chars[j] == " " || chars[j] == "\t" { j += 1 }
                        if j >= n || chars[j] == "\n" {
                            text += run
                            i = j
                            fence = nil
                            lineStart = j < n
                            col = 0
                            continue
                        }
                    }
                }
                text.append(c)
                if c == "\n" { lineStart = true; col = 0 } else { lineStart = false; col = -1000 }
                i += 1
                continue
            }

            // Fenced code opener at the head of a line (≤3 leading spaces).
            if lineStart, col <= 3, c == "`" || c == "~" {
                let run = String(chars[i..<min(i + 3, n)])
                if run.count == 3, run == String(repeating: c, count: 3) {
                    fence = run
                    text += run
                    i += 3
                    lineStart = false
                    col = -1000
                    continue
                }
            }

            switch c {
            case "\n":
                text.append(c)
                lineStart = true
                col = 0
                i += 1
            case "`":
                // Inline code span: skip to the matching backtick on the same
                // line so `$` inside is never treated as math.
                var j = i + 1
                while j < n, chars[j] != "`", chars[j] != "\n" { j += 1 }
                if j < n, chars[j] == "`" {
                    text += String(chars[i...j])
                    i = j + 1
                } else {
                    text.append(c)
                    i += 1
                }
                lineStart = false
                col = -1000
            case "$" where i + 1 < n && chars[i + 1] == "$":
                // Block math.
                if let end = findBlockMathEnd(chars, from: i + 2) {
                    flushText()
                    let latex = String(chars[(i + 2)..<end])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    output.append(.math(inline: false, latex: latex))
                    i = end + 2
                } else {
                    text += "$$"
                    i += 2
                }
                lineStart = false
                col = -1000
            case "$":
                if let close = findInlineMathEnd(chars, openAt: i) {
                    flushText()
                    let latex = String(chars[(i + 1)..<close])
                    output.append(.math(inline: true, latex: latex))
                    i = close + 1
                } else {
                    text.append(c)
                    i += 1
                }
                lineStart = false
                col = -1000
            case " " where lineStart, "\t" where lineStart:
                // Leading indentation: still eligible to open a fence.
                text.append(c)
                col += 1
                i += 1
            default:
                text.append(c)
                lineStart = false
                col = -1000
                i += 1
            }
        }
        flushText()
        return output
    }

    /// Approximate rendered height in points for layout sizing: every
    /// physical line costs one `lineHeight` row — fenced code blocks count
    /// their actual line count (opener, content, closer), so image/math
    /// syntax inside a fence is never mispriced — each standalone image
    /// reserves one `imageHeight` media row, and a `$$…$$` block counts its
    /// content rows (at least 1) instead of the delimiter lines.
    public static func estimatedHeight(of markdown: String, lineHeight: Double, imageHeight: Double) -> Double {
        guard !markdown.isEmpty else { return 0 }
        var height = 0.0
        var fence: Character? = nil
        var inBlockMath = false
        var mathRows = 0
        var lines = markdown.components(separatedBy: "\n")
        // A trailing newline terminates the last line; it is not a new one.
        if lines.last?.isEmpty == true { lines.removeLast() }
        for line in lines {
            let leadingWhitespace = line.prefix(while: { $0 == " " || $0 == "\t" }).count
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let fenceChar = fence {
                height += lineHeight
                // Closing fence: ≥3 of the opener char + optional whitespace.
                if leadingWhitespace <= 3, trimmed.count >= 3,
                   trimmed.allSatisfy({ $0 == fenceChar }) {
                    fence = nil
                }
                continue
            }
            if inBlockMath {
                if trimmed == "$$" {
                    inBlockMath = false
                    height += Double(max(1, mathRows)) * lineHeight
                    mathRows = 0
                } else {
                    mathRows += 1
                }
                continue
            }
            if leadingWhitespace <= 3, trimmed.count >= 3,
               let first = trimmed.first, first == "`" || first == "~",
               trimmed.allSatisfy({ $0 == first }) {
                fence = first
                height += lineHeight
                continue
            }
            if trimmed == "$$" {
                inBlockMath = true
                mathRows = 0
                continue
            }
            if standaloneImage(line) != nil {
                height += imageHeight
                continue
            }
            height += lineHeight
        }
        if inBlockMath {
            // Unmatched opener stayed literal, but the rows still render.
            height += Double(max(1, mathRows)) * lineHeight
        }
        return height
    }

    // MARK: - Internals

    private static func findBlockMathEnd(
        _ chars: [Character], from start: Int
    ) -> Int? {
        var j = start
        let n = chars.count
        while j + 1 < n {
            if chars[j] == "$", chars[j + 1] == "$" { return j }
            j += 1
        }
        return nil
    }

    /// Validates an inline-math opener at `openAt` and returns the index of
    /// the closing `$`, or nil when the rules reject the span.
    private static func findInlineMathEnd(
        _ chars: [Character], openAt: Int
    ) -> Int? {
        let n = chars.count
        let open = openAt
        // Opener: followed by an existing, non-space, non-$ character.
        guard open + 1 < n else { return nil }
        let first = chars[open + 1]
        guard !first.isWhitespace, first != "$" else { return nil }
        // Opener: preceded by start, whitespace, or one of ( [ { > - ~.
        if open > 0 {
            let prev = chars[open - 1]
            guard prev.isWhitespace || "([{>-~".contains(prev) else { return nil }
        }
        // Closer candidates: the first `$` before the next newline, with
        // non-empty content, non-space before the closer, and end/whitespace/
        // punctuation after it.
        var j = open + 1
        while j < n {
            let c = chars[j]
            if c == "\n" || c == "$" { break }
            j += 1
        }
        guard j < n, chars[j] == "$", j > open + 1 else { return nil }
        guard !chars[j - 1].isWhitespace else { return nil }
        let after = j + 1
        if after < n {
            let next = chars[after]
            guard next.isWhitespace || ")],.;:!?".contains(next) else { return nil }
        }
        return j
    }

    /// Splits flushed literal text into text/image segments by checking each
    /// line for a standalone `![alt](url)`.
    private static func appendTextSegments(
        _ t: String, to output: inout [MarkdownSegment]
    ) {
        let lines = t.components(separatedBy: "\n")
        var merged: [MarkdownSegment] = []
        for (idx, line) in lines.enumerated() {
            let hasNewline = idx < lines.count - 1
            if let (alt, url) = standaloneImage(line) {
                merged.append(.image(alt: alt, urlString: url))
                if hasNewline { appendText("\n", to: &merged) }
            } else {
                appendText(hasNewline ? line + "\n" : line, to: &merged)
            }
        }
        // Merge a leading text run into a preceding text segment so adjacent
        // text stays one segment across math boundaries where possible.
        if case .text(let incoming)? = merged.first, case .text(let prev)? = output.last {
            output[output.count - 1] = .text(prev + incoming)
            merged.removeFirst()
        }
        output.append(contentsOf: merged)
    }

    private static func appendText(_ s: String, to merged: inout [MarkdownSegment]) {
        guard !s.isEmpty else { return }
        if case .text(let prev)? = merged.last {
            merged[merged.count - 1] = .text(prev + s)
        } else {
            merged.append(.text(s))
        }
    }

    /// `![alt](url)` alone on a line (after trimming). alt may be empty; the
    /// url must be non-empty, space/paren-free, and http(s) or a data: URI.
    private static func standaloneImage(_ line: String) -> (alt: String, urlString: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("![") else { return nil }
        guard let altRange = trimmed.firstRange(of: "]"),
              trimmed[altRange.upperBound...].hasPrefix("(")
        else { return nil }
        let alt = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<altRange.lowerBound])
        let rest = trimmed[altRange.upperBound...].dropFirst() // after "]"
        guard rest.hasSuffix(")") else { return nil }
        let url = String(rest.dropLast())
        guard !url.isEmpty,
              !url.contains(" "), !url.contains("("), !url.contains(")"),
              url.hasPrefix("http://") || url.hasPrefix("https://") || url.hasPrefix("data:")
        else { return nil }
        return (alt, url)
    }
}
