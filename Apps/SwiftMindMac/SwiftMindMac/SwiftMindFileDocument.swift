import SwiftUI
import SwiftMindCore
import UniformTypeIdentifiers

struct SwiftMindFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.swiftmindHTML, .html] }

    var map: MindMap

    init(map: MindMap = .makeEmpty(title: "Untitled")) {
        self.map = map
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let html = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.map = try HTMLCodec.decode(html)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let html = try HTMLCodec.encode(map, includeSkin: true)
        let data = Data(html.utf8)
        return .init(regularFileWithContents: data)
    }
}
