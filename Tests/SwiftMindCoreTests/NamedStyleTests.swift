import XCTest
@testable import SwiftMindCore

/// Custom named styles: command undo + HTML round-trip.
final class NamedStyleTests: XCTestCase {
    func testCommandRoundTripUndo() throws {
        var map = MindMap.makeEmpty(title: "T")
        let original = map.styleSheet.styles
        let custom = NodeStyle(fontSize: 20, isBold: true,
                               textRed: 0.9, textGreen: 0.2, textBlue: 0.1,
                               fillRed: 1, fillGreen: 0.95, fillBlue: 0.9)
        let bus = CommandBus()
        try bus.execute(SetNamedStylesCommand(styles: ["urgent": custom]), on: &map)
        XCTAssertEqual(map.styleSheet.styles["urgent"], custom)

        try bus.undo(on: &map)
        XCTAssertEqual(map.styleSheet.styles, original)
    }

    func testHTMLRoundTripKeepsCustomStyles() throws {
        var map = MindMap.makeEmpty(title: "T")
        let custom = NodeStyle(fontSize: 18, isBold: false,
                               textRed: 0.1, textGreen: 0.5, textBlue: 0.9,
                               fillRed: 0.9, fillGreen: 0.9, fillBlue: 1)
        map.styleSheet.styles["mine"] = custom

        let html = try HTMLCodec.encode(map, includeSkin: false)
        let decoded = try HTMLCodec.decode(html)
        let out = decoded.styleSheet.styles["mine"]
        XCTAssertNotNil(out)
        // Hex persistence quantizes to 8-bit — compare within 1/255.
        XCTAssertEqual(out?.fontSize, custom.fontSize)
        XCTAssertEqual(out?.isBold, custom.isBold)
        for pair in [(out?.textRed, custom.textRed), (out?.textGreen, custom.textGreen),
                     (out?.textBlue, custom.textBlue), (out?.fillRed, custom.fillRed),
                     (out?.fillGreen, custom.fillGreen), (out?.fillBlue, custom.fillBlue)] {
            XCTAssertEqual(abs((pair.0 ?? 0) - (pair.1 ?? 0)), 0, accuracy: 1.1 / 255)
        }
        XCTAssertNotNil(decoded.styleSheet.styles["topic"])
    }

    func testLegacyFileWithoutSectionKeepsDefaults() throws {
        let html = """
        <article class="swiftmind-map" data-map-id="ns1">
        <section><ul><li data-node-id="root"><span class="node-title">Old</span></li></ul></section>
        </article>
        """
        let decoded = try HTMLCodec.decode(html)
        XCTAssertFalse(decoded.styleSheet.styles.isEmpty,
                       "default sheet styles must survive decoding legacy files")
    }
}
