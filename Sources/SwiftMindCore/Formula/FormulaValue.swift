import Foundation

/// Result of evaluating a formula. Errors are values: any parse/eval failure
/// surfaces as `.error(message)` instead of crashing or going stale.
public enum FormulaValue: Equatable, Sendable {
    case number(Double)
    case string(String)
    case bool(Bool)
    case error(String)

    /// Numeric coercion: numbers pass through, parseable strings convert, anything else fails.
    public var asNumber: Double? {
        switch self {
        case .number(let value): return value
        case .string(let text): return Double(text.trimmingCharacters(in: .whitespaces))
        case .bool, .error: return nil
        }
    }

    /// Smart coercion for raw attribute strings: "42" → number, "true"/"false" → bool, else string.
    public static func fromAttributeString(_ raw: String) -> FormulaValue {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed == "true" { return .bool(true) }
        if trimmed == "false" { return .bool(false) }
        if let number = Double(trimmed) { return .number(number) }
        return .string(raw)
    }

    /// Human-readable rendering for badges / inspector (e.g. `1,240`, `75%` is the UI's job).
    public var displayText: String {
        switch self {
        case .number(let value):
            if value == value.rounded(), abs(value) < 1e15 {
                return String(format: "%.0f", value)
            }
            return String(value)
        case .string(let text): return text
        case .bool(let value): return value ? "true" : "false"
        case .error(let message): return "#ERR: \(message)"
        }
    }
}
