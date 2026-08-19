import Foundation
import SwiftMindCore

/// Shared badge rendering for computed formula values (canvas + outline).
/// Short by design — the full `#ERR: message` lives in the inspector.
enum FormulaBadgeFormatter {
    static func text(for value: FormulaValue, formula: String?) -> String {
        if case .error = value { return "#ERR" }
        // progress() results are 0...1 — show as a percentage.
        if formula?.trimmingCharacters(in: .whitespacesAndNewlines) == "progress()",
           case .number(let fraction) = value {
            return "\(Int((fraction * 100).rounded()))%"
        }
        return value.displayText
    }

    static func isError(_ value: FormulaValue) -> Bool {
        if case .error = value { return true }
        return false
    }
}
