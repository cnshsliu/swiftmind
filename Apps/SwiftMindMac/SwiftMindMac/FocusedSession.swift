import SwiftUI

/// Focused scene value so app-level `Commands` can reach the active document session.
private struct DocumentSessionKey: FocusedValueKey {
    typealias Value = DocumentSession
}

private struct PresentCommandPaletteKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

private struct AppModelKey: FocusedValueKey {
    typealias Value = AppModel
}

extension FocusedValues {
    var documentSession: DocumentSession? {
        get { self[DocumentSessionKey.self] }
        set { self[DocumentSessionKey.self] = newValue }
    }

    /// Binding to present the ⌘K command palette for the focused document window.
    var presentCommandPalette: Binding<Bool>? {
        get { self[PresentCommandPaletteKey.self] }
        set { self[PresentCommandPaletteKey.self] = newValue }
    }

    var appModel: AppModel? {
        get { self[AppModelKey.self] }
        set { self[AppModelKey.self] = newValue }
    }
}
