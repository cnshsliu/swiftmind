import XCTest
@testable import SwiftMindCore

final class AgentProtocolTests: XCTestCase {
    func testMapJSONMergesFormulaResults() throws {
        var map = MindMap.makeEmpty(title: "T")
        let child = NodeID(rawValue: "n_c")
        try InsertChildCommand(parentID: map.root.id, newNodeID: child, text: "C", side: .auto)
            .execute(on: &map)
        try SetFormulaCommand(nodeID: map.root.id, formula: "count(children)").execute(on: &map)

        let results: [NodeID: FormulaValue] = [map.root.id: .number(1)]
        let json = AgentProtocol.mapJSON(for: map, formulaResults: results)
        let root = try XCTUnwrap(json["root"] as? [String: Any])
        XCTAssertEqual(root["formula"] as? String, "count(children)")
        XCTAssertEqual(root["formulaResult"] as? String, "1")
        let children = try XCTUnwrap(root["children"] as? [[String: Any]])
        XCTAssertEqual(children.first?["id"] as? String, "n_c")
        XCTAssertEqual(json["title"] as? String, "T")
    }

    func testMapJSONFormulaWithoutResultOmitsFormulaResult() throws {
        var map = MindMap.makeEmpty(title: "T")
        try SetFormulaCommand(nodeID: map.root.id, formula: "count(children)").execute(on: &map)

        let json = AgentProtocol.mapJSON(for: map)
        let root = try XCTUnwrap(json["root"] as? [String: Any])
        XCTAssertEqual(root["formula"] as? String, "count(children)")
        XCTAssertNil(root["formulaResult"])
    }

    func testMapJSONWithoutFormulasOmitsFormulaResult() {
        let map = MindMap.makeEmpty(title: "T")
        let json = AgentProtocol.mapJSON(for: map)
        let root = json["root"] as? [String: Any]
        XCTAssertNil(root?["formulaResult"])
    }
}
