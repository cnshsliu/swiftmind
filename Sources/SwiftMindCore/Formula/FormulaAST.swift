import Foundation

/// Parsed L1 formula expression tree. Produced by `FormulaParser`, evaluated by `FormulaEvaluator` (Task 2).
public indirect enum FormulaAST: Equatable, Sendable {
    case number(Double)
    case string(String)
    case bool(Bool)
    /// `attr("name")` — reads a node attribute.
    case attribute(name: String)
    /// `sum(children, attr: "x")` / `count(children)` / `progress()` — rolls up over direct children.
    case aggregate(kind: AggregateKind, attribute: String?)
    case unary(UnaryOperator, FormulaAST)
    case binary(BinaryOperator, FormulaAST, FormulaAST)
    /// `if(cond, then, else)`.
    case conditional(condition: FormulaAST, then: FormulaAST, else: FormulaAST)
}

public enum AggregateKind: String, Equatable, Sendable, CaseIterable {
    case sum
    case count
    case avg
    case min
    case max
    case progress
}

public enum UnaryOperator: String, Equatable, Sendable {
    case negate
    case not
}

public enum BinaryOperator: String, Equatable, Sendable {
    case add
    case subtract
    case multiply
    case divide
    case remainder
    case equal
    case notEqual
    case less
    case lessOrEqual
    case greater
    case greaterOrEqual
    case and
    case or
}

/// A lex/parse/eval failure with a position into the formula source (character offset, -1 when N/A).
public struct FormulaError: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    public var position: Int

    public init(message: String, position: Int = -1) {
        self.message = message
        self.position = position
    }

    public var description: String {
        position >= 0 ? "\(message) (at \(position))" : message
    }
}
