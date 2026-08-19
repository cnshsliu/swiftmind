import Foundation

public enum MMImportError: Error, Equatable {
    case notFreeplaneMap
    case parseFailed(String)
}

/// Best-effort Freeplane/FreeMind `.mm` import (one-way — not a codec).
///
/// Imports: node text (`TEXT`), hierarchy, fold state (`FOLDED`), and plain-text
/// notes (`<richcontent TYPE="NOTE">`, tags stripped). Everything else (icons,
/// styles, links, attributes) is dropped by design — this is a migration path,
/// not a renderer for Freeplane files.
public enum MMImport {

    public static func importMap(from xml: String) throws -> MindMap {
        guard let data = xml.data(using: .utf8) else {
            throw MMImportError.parseFailed("Unable to encode as UTF-8")
        }
        let parser = XMLParser(data: data)
        let delegate = MMParserDelegate()
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false

        guard parser.parse(), delegate.error == nil else {
            if let error = delegate.error { throw error }
            throw MMImportError.parseFailed(parser.parserError?.localizedDescription ?? "Unknown parse error")
        }
        guard delegate.sawMapElement else {
            throw MMImportError.notFreeplaneMap
        }
        guard let root = delegate.rootNode else {
            throw MMImportError.parseFailed("Missing root <node>")
        }

        let title = root.text.isEmpty ? "Imported Map" : root.text
        return MindMap(id: "m_" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16)),
                       title: title,
                       root: root)
    }
}

private final class MMParserDelegate: NSObject, XMLParserDelegate {
    var sawMapElement = false
    var rootNode: Node?
    var error: MMImportError?

    private var nodeStack: [Node] = []
    private var idCounter = 0
    /// Depth of `<richcontent TYPE="NOTE">` capture for the current top node.
    private var capturingNote = false
    private var noteBuffer = ""

    private func nextID() -> NodeID {
        idCounter += 1
        return NodeID(rawValue: "n_import_\(idCounter)")
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName.lowercased() {
        case "map":
            sawMapElement = true

        case "node":
            let text = (attributeDict["TEXT"] ?? attributeDict["text"] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let folded = (attributeDict["FOLDED"] ?? "false") == "true"
            nodeStack.append(Node(id: nextID(), text: Self.stripTags(text), isFolded: folded))

        case "richcontent":
            let type = (attributeDict["TYPE"] ?? "").uppercased()
            if type == "NOTE", !nodeStack.isEmpty {
                capturingNote = true
                noteBuffer = ""
            }

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturingNote {
            noteBuffer += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName.lowercased() {
        case "richcontent":
            if capturingNote {
                capturingNote = false
                let note = Self.stripTags(noteBuffer).trimmingCharacters(in: .whitespacesAndNewlines)
                if !note.isEmpty, !nodeStack.isEmpty {
                    nodeStack[nodeStack.count - 1].noteMarkdown = note
                }
            }

        case "node":
            guard !nodeStack.isEmpty else { return }
            let finished = nodeStack.removeLast()
            if nodeStack.isEmpty {
                rootNode = finished
            } else {
                nodeStack[nodeStack.count - 1].children.append(finished)
            }

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        error = .parseFailed(parseError.localizedDescription)
    }

    /// Crude tag stripper for Freeplane's HTML-ish TEXT / note payloads.
    private static func stripTags(_ string: String) -> String {
        var result = ""
        var inTag = false
        for ch in string {
            if ch == "<" { inTag = true; continue }
            if ch == ">" { inTag = false; continue }
            if !inTag { result.append(ch) }
        }
        return result
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
