import Foundation

public enum HTMLCodecError: Error, Equatable {
    case notSwiftMindDocument
    case invalidSchema
    case parseFailed(String)
}

public enum HTMLCodec {
    public static func encode(_ map: MindMap, includeSkin: Bool) throws -> String {
        var out = ""
        out += "<!DOCTYPE html>\n"
        out += "<html lang=\"en\" data-swiftmind-version=\"1\">\n"
        out += "<head>\n"
        out += "<meta charset=\"utf-8\"/>\n"
        out += "<title>\(escapeText(map.title))</title>\n"
        out += HTMLSkin.headFragment(includeSkin: includeSkin)
        out += "</head>\n"
        out += "<body>\n"
        out += "<article class=\"swiftmind-map\" data-schema=\"\(map.schemaVersion)\" data-map-id=\"\(escapeAttribute(map.id))\">\n"
        out += "<ul>\n"
        encodeNode(map.root, into: &out, indent: 2)
        out += "</ul>\n"
        out += "</article>\n"
        out += "</body>\n"
        out += "</html>\n"
        return out
    }

    public static func decode(_ html: String) throws -> MindMap {
        let xml = prepareForXMLParser(html)
        guard let data = xml.data(using: .utf8) else {
            throw HTMLCodecError.parseFailed("Unable to encode HTML as UTF-8")
        }

        let parser = XMLParser(data: data)
        let delegate = DecoderDelegate()
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false

        guard parser.parse() else {
            let message = parser.parserError?.localizedDescription ?? "Unknown parse error"
            if let error = delegate.deferredError {
                throw error
            }
            throw HTMLCodecError.parseFailed(message)
        }

        if let error = delegate.deferredError {
            throw error
        }

        guard delegate.foundSwiftMindArticle else {
            throw HTMLCodecError.notSwiftMindDocument
        }

        guard let root = delegate.rootNode else {
            throw HTMLCodecError.parseFailed("Missing root node")
        }

        guard let mapID = delegate.mapID else {
            throw HTMLCodecError.parseFailed("Missing data-map-id")
        }

        let schema = delegate.schemaVersion ?? 1
        guard schema == 1 else {
            throw HTMLCodecError.invalidSchema
        }

        return MindMap(
            id: mapID,
            title: delegate.title ?? "",
            schemaVersion: schema,
            root: root
        )
    }

    // MARK: - Encode helpers

    private static func encodeNode(_ node: Node, into out: inout String, indent: Int) {
        let pad = String(repeating: " ", count: indent)
        let fill = colorHex(
            red: node.style.fillRed,
            green: node.style.fillGreen,
            blue: node.style.fillBlue
        ) ?? ""

        out += pad
        out += "<li"
        out += " data-node-id=\"\(escapeAttribute(node.id.rawValue))\""
        out += " data-side=\"\(node.side.rawValue)\""
        out += " data-folded=\"\(node.isFolded ? "true" : "false")\""
        out += " data-font-size=\"\(formatNumber(node.style.fontSize))\""
        out += " data-bold=\"\(node.style.isBold ? "true" : "false")\""
        out += " data-text-color=\"\(escapeAttribute(colorHex(red: node.style.textRed, green: node.style.textGreen, blue: node.style.textBlue)))\""
        out += " data-fill-color=\"\(escapeAttribute(fill))\""
        if let pin = node.positionPin {
            out += " data-pin-x=\"\(formatNumber(pin.x))\""
            out += " data-pin-y=\"\(formatNumber(pin.y))\""
        }
        if !node.icons.isEmpty {
            let ids = node.icons.map(\.id).joined(separator: ",")
            out += " data-icons=\"\(escapeAttribute(ids))\""
        }
        out += ">\n"

        out += pad + "  "
        out += "<span class=\"node-title\">\(escapeText(node.text))</span>\n"

        if !node.noteMarkdown.isEmpty {
            out += pad + "  "
            // hidden="hidden" keeps the document well-formed XML for XMLParser.
            out += "<div class=\"node-note\" hidden=\"hidden\">\(escapeText(node.noteMarkdown))</div>\n"
        }

        if !node.links.isEmpty {
            out += pad + "  <ul class=\"node-links\" hidden=\"hidden\">\n"
            for link in node.links {
                out += pad + "    <li"
                switch link {
                case .url(let url):
                    out += " data-link-kind=\"url\""
                    out += " data-href=\"\(escapeAttribute(url.absoluteString))\""
                case .node(let nodeID):
                    out += " data-link-kind=\"node\""
                    out += " data-node-ref=\"\(escapeAttribute(nodeID.rawValue))\""
                }
                out += "></li>\n"
            }
            out += pad + "  </ul>\n"
        }

        if !node.children.isEmpty {
            out += pad + "  <ul>\n"
            for child in node.children {
                encodeNode(child, into: &out, indent: indent + 4)
            }
            out += pad + "  </ul>\n"
        }

        out += pad + "</li>\n"
    }

    private static func prepareForXMLParser(_ html: String) -> String {
        var s = html
        // Strip DOCTYPE so XMLParser accepts the document.
        if let range = s.range(of: "<!DOCTYPE", options: .caseInsensitive) {
            if let end = s[range.lowerBound...].firstIndex(of: ">") {
                s.removeSubrange(range.lowerBound...end)
            }
        }
        // Ensure self-closing void tags are well-formed XML if written without slash.
        // Encode always emits <meta .../>; leave as-is.
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Escaping

    private static func escapeText(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.count)
        for ch in string {
            switch ch {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            default: result.append(ch)
            }
        }
        return result
    }

    private static func escapeAttribute(_ string: String) -> String {
        escapeText(string)
    }

    // MARK: - Colors / numbers

    /// Converts 0...1 sRGB components to `#RRGGBB`. Returns nil if any component is nil.
    static func colorHex(red: Double?, green: Double?, blue: Double?) -> String? {
        guard let r = red, let g = green, let b = blue else { return nil }
        return colorHex(red: r, green: g, blue: b)
    }

    static func colorHex(red: Double, green: Double, blue: Double) -> String {
        let ri = clampByte(red)
        let gi = clampByte(green)
        let bi = clampByte(blue)
        return String(format: "#%02X%02X%02X", ri, gi, bi)
    }

    static func colorComponents(from hex: String) -> (Double, Double, Double)? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        return (r, g, b)
    }

    private static func clampByte(_ component: Double) -> Int {
        let v = min(max(component, 0), 1)
        return Int((v * 255.0).rounded())
    }

    private static func formatNumber(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(value)
    }
}

// MARK: - XMLParser decoder

private final class DecoderDelegate: NSObject, XMLParserDelegate {
    var foundSwiftMindArticle = false
    var mapID: String?
    var schemaVersion: Int?
    var title: String?
    var rootNode: Node?
    var deferredError: HTMLCodecError?

    private var nodeStack: [Node] = []
    private var capturingTitle = false
    private var capturingNodeTitle = false
    private var capturingNote = false
    /// True while inside `<ul class="node-links">` so link `<li>`s are not tree nodes.
    private var inLinksList = false
    private var titleBuffer = ""
    private var nodeTitleBuffer = ""
    private var noteBuffer = ""

    private static func classTokens(_ attributeDict: [String: String]) -> [String] {
        (attributeDict["class"] ?? "")
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = elementName.lowercased()

        switch name {
        case "article":
            let classes = Self.classTokens(attributeDict)
            if classes.contains("swiftmind-map") {
                foundSwiftMindArticle = true
                mapID = attributeDict["data-map-id"]
                if let schema = attributeDict["data-schema"] {
                    if let v = Int(schema) {
                        schemaVersion = v
                    } else {
                        deferredError = .invalidSchema
                        parser.abortParsing()
                    }
                }
            }

        case "title":
            capturingTitle = true
            titleBuffer = ""

        case "ul":
            guard foundSwiftMindArticle else { return }
            let classes = Self.classTokens(attributeDict)
            if classes.contains("node-links") {
                inLinksList = true
            }

        case "li":
            guard foundSwiftMindArticle else { return }

            // Link list items: parse attrs onto current node; never push tree nodes.
            if inLinksList {
                guard !nodeStack.isEmpty else { return }
                let kind = attributeDict["data-link-kind"] ?? ""
                switch kind {
                case "url":
                    if let href = attributeDict["data-href"], let url = URL(string: href) {
                        nodeStack[nodeStack.count - 1].links.append(.url(url))
                    }
                case "node":
                    if let ref = attributeDict["data-node-ref"], !ref.isEmpty {
                        nodeStack[nodeStack.count - 1].links.append(.node(NodeID(rawValue: ref)))
                    }
                default:
                    break
                }
                return
            }

            guard let idRaw = attributeDict["data-node-id"], !idRaw.isEmpty else {
                deferredError = .parseFailed("li missing data-node-id")
                parser.abortParsing()
                return
            }

            let side = NodeSide(rawValue: attributeDict["data-side"] ?? "auto") ?? .auto
            let folded = (attributeDict["data-folded"] ?? "false") == "true"
            let fontSize = Double(attributeDict["data-font-size"] ?? "14") ?? 14
            let isBold = (attributeDict["data-bold"] ?? "false") == "true"

            var textR = 0.0, textG = 0.0, textB = 0.0
            if let hex = attributeDict["data-text-color"],
               let c = HTMLCodec.colorComponents(from: hex) {
                textR = c.0; textG = c.1; textB = c.2
            }

            var fillR: Double?, fillG: Double?, fillB: Double?
            if let fillHex = attributeDict["data-fill-color"], !fillHex.isEmpty,
               let c = HTMLCodec.colorComponents(from: fillHex) {
                fillR = c.0; fillG = c.1; fillB = c.2
            }

            let style = NodeStyle(
                fontSize: fontSize,
                isBold: isBold,
                textRed: textR,
                textGreen: textG,
                textBlue: textB,
                fillRed: fillR,
                fillGreen: fillG,
                fillBlue: fillB
            )

            var positionPin: Point2D?
            if let px = attributeDict["data-pin-x"], let py = attributeDict["data-pin-y"],
               let x = Double(px), let y = Double(py) {
                positionPin = Point2D(x: x, y: y)
            }

            var icons: [NodeIcon] = []
            if let iconsAttr = attributeDict["data-icons"], !iconsAttr.isEmpty {
                icons = iconsAttr
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .map { NodeIcon(id: String($0)) }
            }

            let node = Node(
                id: NodeID(rawValue: idRaw),
                text: "",
                noteMarkdown: "",
                links: [],
                icons: icons,
                isFolded: folded,
                side: side,
                style: style,
                positionPin: positionPin,
                children: []
            )
            nodeStack.append(node)

        case "span":
            guard foundSwiftMindArticle, !inLinksList else { return }
            let classes = Self.classTokens(attributeDict)
            if classes.contains("node-title") {
                capturingNodeTitle = true
                nodeTitleBuffer = ""
            }

        case "div":
            guard foundSwiftMindArticle, !inLinksList else { return }
            let classes = Self.classTokens(attributeDict)
            if classes.contains("node-note") {
                capturingNote = true
                noteBuffer = ""
            }

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturingTitle {
            titleBuffer += string
        }
        if capturingNodeTitle {
            nodeTitleBuffer += string
        }
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
        let name = elementName.lowercased()

        switch name {
        case "title":
            capturingTitle = false
            title = titleBuffer

        case "span":
            if capturingNodeTitle {
                capturingNodeTitle = false
                if !nodeStack.isEmpty {
                    nodeStack[nodeStack.count - 1].text = nodeTitleBuffer
                }
            }

        case "div":
            if capturingNote {
                capturingNote = false
                if !nodeStack.isEmpty {
                    nodeStack[nodeStack.count - 1].noteMarkdown = noteBuffer
                }
            }

        case "ul":
            // Leaving a links list (flat; no nested node-links).
            if inLinksList {
                inLinksList = false
            }

        case "li":
            guard foundSwiftMindArticle else { return }
            // Link items were never pushed onto the node stack.
            if inLinksList {
                return
            }
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
}
