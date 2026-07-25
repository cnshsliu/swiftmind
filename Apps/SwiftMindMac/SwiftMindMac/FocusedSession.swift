import SwiftUI

/// Focused scene value so app-level `Commands` can reach the active document session.
private struct DocumentSessionKey: FocusedValueKey {
    typealias Value = DocumentSession
}

extension FocusedValues {
    var documentSession: DocumentSession? {
        get { self[DocumentSessionKey.self] }
        set { self[DocumentSessionKey.self] = newValue }
    }
}
