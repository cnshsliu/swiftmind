import SwiftUI
import SwiftMindCore

/// Compact filter controls: text query + hide/highlight mode + clear.
struct FilterBarView: View {
    @ObservedObject var session: DocumentSession

    @State private var queryDraft: String = ""
    @State private var mode: FilterMode = .hide
    @FocusState private var queryFocused: Bool

    private var activeFilter: MapFilter? {
        session.store.map.activeFilter
    }

    private var isFilterOn: Bool {
        activeFilter != nil
    }

    private var visibleCount: Int {
        session.store.snapshot().nodes.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("FILTER")
                .font(Theme.sidebarCaption)
                .foregroundStyle(.secondary)
                .tracking(0.6)

            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(isFilterOn ? Color.accentColor : Color.secondary)
                TextField("Filter text…", text: $queryDraft)
                    .textFieldStyle(.plain)
                    .focused($queryFocused)
                    .accessibilityIdentifier("filterQueryField")
                    .onSubmit { applyFilter() }
                if isFilterOn || !queryDraft.isEmpty {
                    Button {
                        clearFilter()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear filter")
                    .accessibilityIdentifier("clearFilterButton")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            )

            Picker("Mode", selection: $mode) {
                Text("Hide").tag(FilterMode.hide)
                Text("Highlight").tag(FilterMode.highlight)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("filterModePicker")
            .onChange(of: mode) { _, _ in
                if isFilterOn || !queryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    applyFilter()
                }
            }

            if isFilterOn {
                Text(statusLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("filterStatusLabel")
            }
        }
        .onAppear {
            syncFromModel()
        }
        .onChange(of: session.contentRevision) { _, _ in
            if !queryFocused {
                syncFromModel()
            }
        }
    }

    private var statusLabel: String {
        switch activeFilter?.mode {
        case .hide:
            return "Filter on · \(visibleCount) visible"
        case .highlight:
            let hits = session.store.snapshot().nodes.filter(\.isHighlighted).count
            return "Filter on · \(hits) highlighted"
        case .none:
            return ""
        }
    }

    private func syncFromModel() {
        if let filter = activeFilter {
            mode = filter.mode
            switch filter.rule {
            case .textContains(let q):
                queryDraft = q
            case .hasIcon(let id):
                queryDraft = id
            case .attributeEquals(let name, let value):
                queryDraft = "\(name)=\(value)"
            case .and, .or:
                queryDraft = ""
            }
        } else if !queryFocused {
            // Keep draft if user is typing; clear when model has no filter and not focused.
            if queryDraft.isEmpty {
                mode = .hide
            }
        }
    }

    private func applyFilter() {
        let trimmed = queryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if activeFilter != nil {
                session.applyQuiet(SetFilterCommand(filter: nil))
            }
            return
        }
        // Attr shortcut: name=value
        let rule: FilterRule
        if let eq = trimmed.firstIndex(of: "="),
           trimmed.distance(from: trimmed.startIndex, to: eq) > 0 {
            let name = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            rule = .attributeEquals(name: name, value: value)
        } else {
            rule = .textContains(trimmed)
        }
        session.applyQuiet(SetFilterCommand(filter: MapFilter(mode: mode, rule: rule)))
    }

    private func clearFilter() {
        queryDraft = ""
        session.applyQuiet(SetFilterCommand(filter: nil))
    }
}
