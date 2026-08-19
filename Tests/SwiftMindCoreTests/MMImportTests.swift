import XCTest
@testable import SwiftMindCore

final class MMImportTests: XCTestCase {

    private func fixtureXML() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/sample.mm")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testImportHierarchyAndText() throws {
        let map = try MMImport.importMap(from: fixtureXML())

        XCTAssertEqual(map.title, "Project Plan")
        XCTAssertEqual(map.root.text, "Project Plan")
        XCTAssertEqual(map.root.children.map(\.text), ["Phase One", "Phase Two"])
        XCTAssertEqual(map.root.children[0].children.map(\.text), ["Kickoff", "Execution"])
        XCTAssertEqual(map.root.children[1].children.map(\.text), ["Retro"])
    }

    func testImportFoldAndNote() throws {
        let map = try MMImport.importMap(from: fixtureXML())
        let kickoff = map.root.children[0].children[0]

        XCTAssertTrue(kickoff.isFolded)
        XCTAssertEqual(kickoff.noteMarkdown, "Bring \"snacks\" & drinks")
        XCTAssertFalse(map.root.isFolded)
    }

    func testImportedMapIsUsable() throws {
        // Imported maps must flow through the normal store/commands/codec paths.
        let map = try MMImport.importMap(from: fixtureXML())
        let store = MapStore(map: map)
        XCTAssertGreaterThan(store.snapshot().nodes.count, 0)

        let html = try HTMLCodec.encode(map, includeSkin: false)
        let roundTripped = try HTMLCodec.decode(html)
        XCTAssertEqual(roundTripped.root.children.count, 2)
    }

    func testRejectsNonFreeplaneXML() {
        XCTAssertThrowsError(try MMImport.importMap(from: "<html><body>nope</body></html>")) { error in
            XCTAssertEqual(error as? MMImportError, .notFreeplaneMap)
        }
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try MMImport.importMap(from: "not xml at all {{{"))
    }

    func testMapWithoutRootNodeFails() {
        XCTAssertThrowsError(try MMImport.importMap(from: "<map version=\"1.0.1\"></map>"))
    }
}
