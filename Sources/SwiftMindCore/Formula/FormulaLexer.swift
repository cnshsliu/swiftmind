import Foundation

/// A lexed token with its character offset in the source (for error messages).
public struct FormulaToken: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case number(Double)
        case string(String)
        case identifier(String)
        case lparen
        case rparen
        case comma
        case colon
        case `operator`(String)
    }

    public var kind: Kind
    public var position: Int

    public init(kind: Kind, position: Int) {
        self.kind = kind
        self.position = position
    }
}

/// Tokenizes L1 formula source. Throws `FormulaError` on malformed input.
public enum FormulaLexer {

    public static func tokenize(_ source: String) throws -> [FormulaToken] {
        let chars = Array(source)
        var tokens: [FormulaToken] = []
        var i = 0

        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace {
                i += 1
                continue
            }
            switch c {
            case "(":
                tokens.append(FormulaToken(kind: .lparen, position: i)); i += 1
            case ")":
                tokens.append(FormulaToken(kind: .rparen, position: i)); i += 1
            case ",":
                tokens.append(FormulaToken(kind: .comma, position: i)); i += 1
            case ":":
                tokens.append(FormulaToken(kind: .colon, position: i)); i += 1
            case "\"":
                let (value, next) = try lexString(chars, from: i)
                tokens.append(FormulaToken(kind: .string(value), position: i))
                i = next
            case let d where d.isNumber:
                let (value, next) = try lexNumber(chars, from: i)
                tokens.append(FormulaToken(kind: .number(value), position: i))
                i = next
            case let l where l.isLetter || l == "_":
                let (name, next) = lexIdentifier(chars, from: i)
                tokens.append(FormulaToken(kind: .identifier(name), position: i))
                i = next
            case "+", "-", "*", "/", "%":
                tokens.append(FormulaToken(kind: .operator(String(c)), position: i)); i += 1
            case "=", "!", "<", ">":
                let (op, next) = try lexComparison(chars, from: i)
                tokens.append(FormulaToken(kind: .operator(op), position: i))
                i = next
            default:
                throw FormulaError(message: "unexpected character \"\(c)\"", position: i)
            }
        }
        return tokens
    }

    // MARK: - Token scanners

    private static func lexString(_ chars: [Character], from start: Int) throws -> (String, Int) {
        var i = start + 1
        var value = ""
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                return (value, i + 1)
            }
            if c == "\\", i + 1 < chars.count {
                let escaped = chars[i + 1]
                guard escaped == "\"" || escaped == "\\" else {
                    throw FormulaError(message: "unsupported escape \"\\\(escaped)\"", position: i)
                }
                value.append(escaped)
                i += 2
                continue
            }
            value.append(c)
            i += 1
        }
        throw FormulaError(message: "unterminated string", position: start)
    }

    private static func lexNumber(_ chars: [Character], from start: Int) throws -> (Double, Int) {
        var i = start
        var seenDot = false
        while i < chars.count {
            let c = chars[i]
            if c.isNumber {
                i += 1
            } else if c == ".", !seenDot, i + 1 < chars.count, chars[i + 1].isNumber {
                seenDot = true
                i += 1
            } else {
                break
            }
        }
        let text = String(chars[start..<i])
        guard let value = Double(text) else {
            throw FormulaError(message: "invalid number \"\(text)\"", position: start)
        }
        return (value, i)
    }

    private static func lexIdentifier(_ chars: [Character], from start: Int) -> (String, Int) {
        var i = start
        while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" {
            i += 1
        }
        return (String(chars[start..<i]), i)
    }

    private static func lexComparison(_ chars: [Character], from start: Int) throws -> (String, Int) {
        let c = chars[start]
        let hasNext = start + 1 < chars.count
        switch c {
        case "=":
            guard hasNext, chars[start + 1] == "=" else {
                throw FormulaError(message: "unexpected \"=\" (did you mean \"==\"?)", position: start)
            }
            return ("==", start + 2)
        case "!":
            guard hasNext, chars[start + 1] == "=" else {
                throw FormulaError(message: "unexpected \"!\" (did you mean \"!=\"?)", position: start)
            }
            return ("!=", start + 2)
        case "<":
            if hasNext, chars[start + 1] == "=" { return ("<=", start + 2) }
            return ("<", start + 1)
        case ">":
            if hasNext, chars[start + 1] == "=" { return (">=", start + 2) }
            return (">", start + 1)
        default:
            throw FormulaError(message: "unexpected character \"\(c)\"", position: start)
        }
    }
}
