import Foundation

/// Recursive-descent parser for the L1 formula DSL.
///
/// Precedence (loosest to tightest): `or` < `and` < comparison < `+ -` < `* / %` < unary (`-`, `not`) < atom.
/// `not` binds tighter than comparison: `not a == b` parses as `(not a) == b`.
public enum FormulaParser {

    /// Parses formula source into an AST. Throws `FormulaError` on any malformed input.
    public static func parse(_ source: String) throws -> FormulaAST {
        let tokens = try FormulaLexer.tokenize(source)
        var parser = Parser(tokens: tokens)
        let ast = try parser.parseOr()
        try parser.expectEnd()
        return ast
    }
}

private struct Parser {
    let tokens: [FormulaToken]
    var index = 0

    // MARK: - Precedence levels

    mutating func parseOr() throws -> FormulaAST {
        var lhs = try parseAnd()
        while matchIdentifier("or") {
            let rhs = try parseAnd()
            lhs = .binary(.or, lhs, rhs)
        }
        return lhs
    }

    mutating func parseAnd() throws -> FormulaAST {
        var lhs = try parseComparison()
        while matchIdentifier("and") {
            let rhs = try parseComparison()
            lhs = .binary(.and, lhs, rhs)
        }
        return lhs
    }

    mutating func parseComparison() throws -> FormulaAST {
        var lhs = try parseAdditive()
        while let op = matchOperator(["==", "!=", "<", "<=", ">", ">="]) {
            let binOp: BinaryOperator
            switch op {
            case "==": binOp = .equal
            case "!=": binOp = .notEqual
            case "<": binOp = .less
            case "<=": binOp = .lessOrEqual
            case ">": binOp = .greater
            default: binOp = .greaterOrEqual
            }
            let rhs = try parseAdditive()
            lhs = .binary(binOp, lhs, rhs)
        }
        return lhs
    }

    mutating func parseAdditive() throws -> FormulaAST {
        var lhs = try parseMultiplicative()
        while let op = matchOperator(["+", "-"]) {
            let rhs = try parseMultiplicative()
            lhs = .binary(op == "+" ? .add : .subtract, lhs, rhs)
        }
        return lhs
    }

    mutating func parseMultiplicative() throws -> FormulaAST {
        var lhs = try parseUnary()
        while let op = matchOperator(["*", "/", "%"]) {
            let rhs = try parseUnary()
            let binOp: BinaryOperator = op == "*" ? .multiply : (op == "/" ? .divide : .remainder)
            lhs = .binary(binOp, lhs, rhs)
        }
        return lhs
    }

    mutating func parseUnary() throws -> FormulaAST {
        if matchOperator(["-"]) != nil {
            return .unary(.negate, try parseUnary())
        }
        if matchIdentifier("not") {
            return .unary(.not, try parseUnary())
        }
        return try parseAtom()
    }

    // MARK: - Atoms

    mutating func parseAtom() throws -> FormulaAST {
        guard let token = peek() else {
            throw FormulaError(message: "unexpected end of formula")
        }
        switch token.kind {
        case .number(let value):
            advance()
            return .number(value)
        case .string(let value):
            advance()
            return .string(value)
        case .lparen:
            advance()
            let inner = try parseOr()
            try expect(.rparen)
            return inner
        case .identifier(let name):
            return try parseIdentifierForm(name, position: token.position)
        default:
            throw FormulaError(message: "unexpected \(describe(token))", position: token.position)
        }
    }

    mutating func parseIdentifierForm(_ name: String, position: Int) throws -> FormulaAST {
        switch name {
        case "true":
            advance()
            return .bool(true)
        case "false":
            advance()
            return .bool(false)
        case "attr":
            advance()
            try expect(.lparen)
            let attrName = try expectString()
            try expect(.rparen)
            return .attribute(name: attrName)
        case "if":
            advance()
            try expect(.lparen)
            let condition = try parseOr()
            try expect(.comma)
            let thenBranch = try parseOr()
            try expect(.comma)
            let elseBranch = try parseOr()
            try expect(.rparen)
            return .conditional(condition: condition, then: thenBranch, else: elseBranch)
        case "sum", "avg", "min", "max":
            advance()
            try expect(.lparen)
            try expectIdentifier("children")
            try expect(.comma)
            try expectIdentifier("attr")
            try expect(.colon)
            let attrName = try expectString()
            try expect(.rparen)
            return .aggregate(kind: AggregateKind(rawValue: name)!, attribute: attrName)
        case "count":
            advance()
            try expect(.lparen)
            try expectIdentifier("children")
            try expect(.rparen)
            return .aggregate(kind: .count, attribute: nil)
        case "progress":
            advance()
            try expect(.lparen)
            try expect(.rparen)
            return .aggregate(kind: .progress, attribute: nil)
        default:
            throw FormulaError(
                message: "unknown identifier \"\(name)\" (expected attr(...), sum/count/avg/min/max(...), progress(), or if(...))",
                position: position
            )
        }
    }

    // MARK: - Token helpers

    func peek() -> FormulaToken? {
        index < tokens.count ? tokens[index] : nil
    }

    mutating func advance() {
        index += 1
    }

    /// Consumes the next token if it is one of the given operators; returns the operator text.
    mutating func matchOperator(_ ops: [String]) -> String? {
        guard let token = peek(), case .operator(let op) = token.kind, ops.contains(op) else { return nil }
        advance()
        return op
    }

    /// Consumes the next token if it is an identifier with the given text.
    mutating func matchIdentifier(_ text: String) -> Bool {
        guard let token = peek(), case .identifier(let name) = token.kind, name == text else { return false }
        advance()
        return true
    }

    mutating func expect(_ kind: FormulaToken.Kind) throws {
        guard let token = peek(), token.kind == kind else {
            if let token = peek() {
                throw FormulaError(message: "expected \(describe(kind)), got \(describe(token))", position: token.position)
            }
            throw FormulaError(message: "expected \(describe(kind)), got end of formula")
        }
        advance()
    }

    mutating func expectIdentifier(_ text: String) throws {
        guard let token = peek(), case .identifier(let name) = token.kind, name == text else {
            if let token = peek() {
                throw FormulaError(message: "expected \"\(text)\", got \(describe(token))", position: token.position)
            }
            throw FormulaError(message: "expected \"\(text)\", got end of formula")
        }
        advance()
    }

    mutating func expectString() throws -> String {
        guard let token = peek(), case .string(let value) = token.kind else {
            if let token = peek() {
                throw FormulaError(message: "expected a quoted string, got \(describe(token))", position: token.position)
            }
            throw FormulaError(message: "expected a quoted string, got end of formula")
        }
        advance()
        return value
    }

    mutating func expectEnd() throws {
        if let token = peek() {
            throw FormulaError(message: "unexpected \(describe(token)) after complete expression", position: token.position)
        }
    }

    // MARK: - Error descriptions

    func describe(_ token: FormulaToken) -> String {
        describe(token.kind)
    }

    func describe(_ kind: FormulaToken.Kind) -> String {
        switch kind {
        case .number(let value): return "number \(value)"
        case .string(let value): return "string \"\(value)\""
        case .identifier(let name): return "\"\(name)\""
        case .lparen: return "\"(\""
        case .rparen: return "\")\""
        case .comma: return "\",\""
        case .colon: return "\":\""
        case .operator(let op): return "\"\(op)\""
        }
    }
}
