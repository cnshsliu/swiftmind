import SwiftUI

struct ContentView: View {
    @Binding var document: SwiftMindFileDocument

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 8) {
                Text("SwiftMind")
                    .font(.headline)
                Text(document.map.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Divider()
                Text("Outline")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                // Placeholder for outline later
                Text(document.map.root.text)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding()
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            VStack(spacing: 12) {
                Text(document.map.title)
                    .font(.title2)
                Text(document.map.root.text)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Map canvas placeholder")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 640, minHeight: 420)
    }
}

#Preview {
    ContentView(document: .constant(SwiftMindFileDocument()))
}
