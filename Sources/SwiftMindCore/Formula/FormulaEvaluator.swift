import Foundation

/// Evaluates a `FormulaAST` against a node. Pure and side-effect free: reads the
/// node's attributes and children, never mutates. All failures return `.error`.
public enum FormulaEvaluator {

    /// Icon id that marks a node "done" for `progress()`.
    public static let doneIconID = "check"

    public static func evaluate(_ ast: FormulaAST, on node: Node) -> FormulaValue {
        switch ast {
        case .number(let value):
            return .number(value)
        case .string(let value):
            return .string(value)
        case .bool(let value):
            return .bool(value)

        case .attribute(let name):
            guard let raw = node.attributeValue(named: name) else {
                return .error("unknown attribute \"\(name)\"")
            }
            return .fromAttributeString(raw)

        case .aggregate(let kind, let attribute):
            return evaluateAggregate(kind: kind, attribute: attribute, on: node)

        case .unary(let op, let operand):
            let value = evaluate(operand, on: node)
            if case .error = value { return value }
            switch op {
            case .negate:
                guard let number = value.asNumber else {
                    return .error("cannot negate \(typeName(value))")
                }
                return .number(-number)
            case .not:
                guard case .bool(let flag) = value else {
                    return .error("not expects a bool, got \(typeName(value))")
                }
                return .bool(!flag)
            }

        case .binary(let op, let lhsAST, let rhsAST):
            let lhs = evaluate(lhsAST, on: node)
            if case .error = lhs { return lhs }
            let rhs = evaluate(rhsAST, on: node)
            if case .error = rhs { return rhs }
            return evaluateBinary(op: op, lhs: lhs, rhs: rhs)

        case .conditional(let condition, let thenBranch, let elseBranch):
            let conditionValue = evaluate(condition, on: node)
            if case .error = conditionValue { return conditionValue }
            guard case .bool(let flag) = conditionValue else {
                return .error("if condition must be a bool, got \(typeName(conditionValue))")
            }
            // Lazy: only the taken branch is evaluated.
            return evaluate(flag ? thenBranch : elseBranch, on: node)
        }
    }

    /// Convenience: parse + evaluate in one call. Parse failures return `.error`.
    public static func evaluate(source: String, on node: Node) -> FormulaValue {
        do {
            let ast = try FormulaParser.parse(source)
            return evaluate(ast, on: node)
        } catch let error as FormulaError {
            return .error(error.message)
        } catch {
            return .error("\(error)")
        }
    }

    // MARK: - Aggregates

    private static func evaluateAggregate(kind: AggregateKind, attribute: String?, on node: Node) -> FormulaValue {
        switch kind {
        case .count:
            return .number(Double(node.children.count))

        case .progress:
            var total = 0
            var done = 0
            countProgress(node: node, total: &total, done: &done)
            guard total > 0 else { return .number(0) }
            return .number(Double(done) / Double(total))

        case .sum, .avg, .min, .max:
            guard let attribute else {
                return .error("\(kind.rawValue) requires an attribute")
            }
            var numbers: [Double] = []
            for child in node.children {
                guard let raw = child.attributeValue(named: attribute) else { continue } // missing → skip
                guard let value = FormulaValue.fromAttributeString(raw).asNumber else {
                    return .error("attribute \"\(attribute)\" on \"\(child.text)\" is not a number")
                }
                numbers.append(value)
            }
            switch kind {
            case .sum:
                return .number(numbers.reduce(0, +))
            case .avg:
                guard !numbers.isEmpty else { return .error("avg over no numeric values") }
                return .number(numbers.reduce(0, +) / Double(numbers.count))
            case .min:
                guard let smallest = numbers.min() else { return .error("min over no numeric values") }
                return .number(smallest)
            case .max:
                guard let largest = numbers.max() else { return .error("max over no numeric values") }
                return .number(largest)
            default:
                preconditionFailure("unreachable")
            }
        }
    }

    /// `progress()` = checked descendants / total descendants (icon `check` = done).
    private static func countProgress(node: Node, total: inout Int, done: inout Int) {
        for child in node.children {
            total += 1
            if child.icons.contains(where: { $0.id == doneIconID }) { done += 1 }
            countProgress(node: child, total: &total, done: &done)
        }
    }

    // MARK: - Binary operators

    private static func evaluateBinary(op: BinaryOperator, lhs: FormulaValue, rhs: FormulaValue) -> FormulaValue {
        switch op {
        case .add, .subtract, .multiply, .divide, .remainder:
            guard let a = lhs.asNumber else {
                return .error("cannot use \(typeName(lhs)) in arithmetic")
            }
            guard let b = rhs.asNumber else {
                return .error("cannot use \(typeName(rhs)) in arithmetic")
            }
            switch op {
            case .add: return .number(a + b)
            case .subtract: return .number(a - b)
            case .multiply: return .number(a * b)
            case .divide:
                guard b != 0 else { return .error("division by zero") }
                return .number(a / b)
            case .remainder:
                guard b != 0 else { return .error("division by zero") }
                return .number(a.truncatingRemainder(dividingBy: b))
            default:
                preconditionFailure("unreachable")
            }

        case .equal, .notEqual:
            let equal = valuesEqual(lhs, rhs)
            return .bool(op == .equal ? equal : !equal)

        case .less, .lessOrEqual, .greater, .greaterOrEqual:
            guard let comparison = compareOrdered(lhs, rhs) else {
                return .error("cannot compare \(typeName(lhs)) and \(typeName(rhs))")
            }
            switch op {
            case .less: return .bool(comparison < 0)
            case .lessOrEqual: return .bool(comparison <= 0)
            case .greater: return .bool(comparison > 0)
            case .greaterOrEqual: return .bool(comparison >= 0)
            default:
                preconditionFailure("unreachable")
            }

        case .and, .or:
            guard case .bool(let a) = lhs else {
                return .error("\(op.rawValue) expects a bool, got \(typeName(lhs))")
            }
            guard case .bool(let b) = rhs else {
                return .error("\(op.rawValue) expects a bool, got \(typeName(rhs))")
            }
            return .bool(op == .and ? a && b : a || b)
        }
    }

    /// Equality: numeric compare when both sides coerce to numbers, otherwise strict type+value.
    private static func valuesEqual(_ lhs: FormulaValue, _ rhs: FormulaValue) -> Bool {
        if let a = lhs.asNumber, let b = rhs.asNumber { return a == b }
        switch (lhs, rhs) {
        case (.string(let a), .string(let b)): return a == b
        case (.bool(let a), .bool(let b)): return a == b
        default: return false
        }
    }

    /// Ordering: numeric when both coerce, lexicographic for two strings, else nil (incomparable).
    private static func compareOrdered(_ lhs: FormulaValue, _ rhs: FormulaValue) -> Int? {
        if let a = lhs.asNumber, let b = rhs.asNumber {
            return a < b ? -1 : (a > b ? 1 : 0)
        }
        if case .string(let a) = lhs, case .string(let b) = rhs {
            return a < b ? -1 : (a > b ? 1 : 0)
        }
        return nil
    }

    private static func typeName(_ value: FormulaValue) -> String {
        switch value {
        case .number: return "a number"
        case .string: return "a string"
        case .bool: return "a bool"
        case .error: return "an error"
        }
    }
}
