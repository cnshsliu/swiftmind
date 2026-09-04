/// Recursive-descent parser for a pragmatic LaTeX subset. Never throws:
/// unmatched braces and unknown constructs degrade to literal `.run`s so
/// content is never lost.
indirect enum MathAST: Equatable {
    /// Plain glyphs (symbol commands already resolved to Unicode).
    case run(String)
    /// `{...}` grouping.
    case group([MathAST])
    /// `\name{arg1}{arg2}…`; zero-arg commands arrive as `run` glyphs.
    case command(name: String, args: [[MathAST]])
    /// Base atom with attached `^{}` and/or `_{}`.
    case scripts(base: MathAST, sup: MathAST?, sub: MathAST?)
    /// `\text{...}` — upright roman content.
    case text(String)
    /// A fixed horizontal gap (`\,` `\;` `\:` `\quad` …). Points at fontSize 12.
    case space(Double)
}

enum LaTeXParser {
    static func rows(_ latex: String) -> [[MathAST]] {
        parseTokens(Array(latex)).rows
    }

    static func parse(_ latex: String) -> [MathAST] {
        rows(latex).first ?? []
    }

    // MARK: - Tokenizer + parser (single pass)

    private struct Token {
        enum Kind { case chars(String), command(String), lbrace, rbrace, sup, sub, rowBreak, space(Double), amp }
        var kind: Kind
    }

    private static func parseTokens(_ chars: [Character]) -> (rows: [[MathAST]], remainder: [MathAST]) {
        var rows: [[MathAST]] = []
        var current: [MathAST] = []
        var i = 0
        let n = chars.count

        while i < n {
            let c = chars[i]
            switch c {
            case "\\":
                guard i + 1 < n else { i += 1; break }
                let next = chars[i + 1]
                if next.isLetter {
                    var j = i + 1
                    while j < n, chars[j].isLetter { j += 1 }
                    let name = String(chars[(i + 1)..<j])
                    i = j
                    switch name {
                    case "text", "mathrm", "operatorname", "mathbf", "mathit", "textrm":
                        // Consume one brace group as literal content.
                        let (content, nextI) = readBraceLiteral(chars, from: i)
                        current.append(.text(content))
                        i = nextI
                    case "left", "right":
                        // \left( \right) \right. → plain delimiter char.
                        if i < n, chars[i] != "{" {
                            let d = chars[i]
                            if d != "." { current.append(.run(String(d))) }
                            i += 1
                        } else { i += 1 }
                    case "displaystyle", "textstyle", "limits", "nolimits":
                        continue
                    default:
                        if let glyph = LaTeXSymbols.names[name] {
                            current.append(.run(glyph))
                        } else if name == "quad" {
                            current.append(.space(12))
                        } else if name == "qquad" {
                            current.append(.space(24))
                        } else if name == "thinspace" {
                            current.append(.space(3))
                        } else if ["frac", "dfrac", "tfrac", "binom", "sqrt"].contains(name) {
                            let (arg1, i1) = readGroup(chars, from: i)
                            var args: [[MathAST]] = [arg1]
                            i = i1
                            if name != "sqrt" {
                                let (arg2, i2) = readGroup(chars, from: i)
                                args.append(arg2)
                                i = i2
                            }
                            current.append(.command(name: name == "sqrt" ? "sqrt" : "frac", args: args))
                        } else {
                            // Unknown command: keep it visible, never drop content.
                            current.append(.command(name: name, args: []))
                        }
                    }
                } else if next == "\\" {
                    rows.append(current); current = []
                    i += 2
                } else if next == "," || next == ";" || next == ":" {
                    current.append(.space(next == "," ? 3 : 4))
                    i += 2
                } else if next == "!" {
                    current.append(.space(0))
                    i += 2
                } else if next == " " {
                    i += 2 // "\ " explicit space
                } else {
                    current.append(.run(String(next)))
                    i += 2
                }
            case "{":
                let (group, nextI) = readGroup(chars, from: i)
                current.append(.group(group))
                i = nextI
            case "}":
                // Stray close brace: literal.
                current.append(.run("}"))
                i += 1
            case "^", "_":
                var j = i + 1
                var arg: [MathAST] = []
                if j < n, chars[j] == "{" {
                    let (g, nj) = readGroup(chars, from: j)
                    arg = g; j = nj
                } else if j < n, chars[j] == "\\" {
                    // single command token
                    var k = j + 1
                    if k < n, chars[k].isLetter {
                        while k < n, chars[k].isLetter { k += 1 }
                        let name = String(chars[(j + 1)..<k])
                        arg = [.run(LaTeXSymbols.names[name] ?? "\\(name)")]
                        j = k
                    } else if k < n {
                        arg = [.run(String(chars[k]))]
                        j = k + 1
                    } else { j = k }
                } else if j < n {
                    arg = [.run(String(chars[j]))]
                    j += 1
                }
                let script: MathAST = .group(arg)
                let isSup = c == "^"
                if var last = current.last {
                    current.removeLast()
                    if case .scripts(let base, let sup, let sub) = last {
                        last = .scripts(
                            base: base,
                            sup: isSup ? script : sup,
                            sub: isSup ? sub : script
                        )
                    } else {
                        last = .scripts(base: last, sup: isSup ? script : nil, sub: isSup ? nil : script)
                    }
                    current.append(last)
                } else {
                    current.append(script)
                }
                i = j
            case "&":
                current.append(.space(12))
                i += 1
            case "\n", "\r":
                // Newlines inside math are spaces (except rowBreak handled above).
                current.append(.space(4))
                i += 1
            case " ", "\t":
                i += 1 // math ignores whitespace
            default:
                // Accumulate plain glyph runs.
                var j = i
                while j < n {
                    let d = chars[j]
                    if "\\{}^_&\n\r \t".contains(d) { break }
                    j += 1
                }
                current.append(.run(String(chars[i..<j])))
                i = j
            }
        }
        rows.append(current)
        return (rows, [])
    }

    /// Reads a `{...}` group starting at `from` (which must be `{` or the
    /// next non-space char). Returns the parsed atoms and the index after
    /// the closing brace. Unmatched braces swallow the rest of the input.
    private static func readGroup(_ chars: [Character], from start: Int) -> ([MathAST], Int) {
        var i = start
        let n = chars.count
        while i < n, chars[i] == " " { i += 1 }
        guard i < n, chars[i] == "{" else {
            // Single-token group: `-`, `2`, `\alpha`, …
            if i < n {
                let (atoms, nextI) = parseSingleToken(chars, from: i)
                return (atoms, nextI)
            }
            return ([], i)
        }
        var depth = 1
        i += 1
        let contentStart = i
        while i < n {
            if chars[i] == "{" { depth += 1 }
            else if chars[i] == "}" {
                depth -= 1
                if depth == 0 {
                    let inner = Array(chars[contentStart..<i])
                    return (parseTokens(inner).rows.first ?? [], i + 1)
                }
            }
            i += 1
        }
        // Unmatched: everything to the end is the group.
        let inner = Array(chars[contentStart...])
        return (parseTokens(inner).rows.first ?? [], n)
    }

    private static func parseSingleToken(_ chars: [Character], from i: Int) -> ([MathAST], Int) {
        let n = chars.count
        let c = chars[i]
        if c == "\\" {
            var k = i + 1
            if k < n, chars[k].isLetter {
                while k < n, chars[k].isLetter { k += 1 }
                let name = String(chars[(i + 1)..<k])
                return ([.run(LaTeXSymbols.names[name] ?? "\\(name)")], k)
            }
            if k < n { return ([.run(String(chars[k]))], k + 1) }
            return ([], k)
        }
        return ([.run(String(c))], i + 1)
    }

    /// Reads a `{...}` group as plain literal text (for `\text{}`).
    private static func readBraceLiteral(_ chars: [Character], from start: Int) -> (String, Int) {
        var i = start
        let n = chars.count
        while i < n, chars[i] == " " { i += 1 }
        guard i < n, chars[i] == "{" else { return ("", i) }
        var depth = 1
        i += 1
        let contentStart = i
        while i < n {
            if chars[i] == "{" { depth += 1 }
            else if chars[i] == "}" {
                depth -= 1
                if depth == 0 {
                    return (String(chars[contentStart..<i]), i + 1)
                }
            }
            i += 1
        }
        return (String(chars[contentStart...]), n)
    }
}
