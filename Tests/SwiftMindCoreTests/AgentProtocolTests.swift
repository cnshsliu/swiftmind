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

    func testReadJSONExposesNoteExpanded() throws {
        var map = MindMap.makeEmpty(title: "T")
        let bus = CommandBus()
        try bus.execute(
            InsertChildCommand(parentID: map.root.id, newNodeID: NodeID(rawValue: "n_j"), text: "J", side: .right),
            on: &map
        )
        var json = AgentProtocol.mapJSON(for: map)
        var child = (json["root"] as! [String: Any])["children"] as! [[String: Any]]
        XCTAssertNil(child[0]["noteExpanded"])

        map.updateNode(id: NodeID(rawValue: "n_j")) { $0.isNoteExpanded = true }
        json = AgentProtocol.mapJSON(for: map)
        child = (json["root"] as! [String: Any])["children"] as! [[String: Any]]
        XCTAssertEqual(child[0]["noteExpanded"] as? Bool, true)
    }

    func testMapJSONWithoutFormulasOmitsFormulaResult() {
        let map = MindMap.makeEmpty(title: "T")
        let json = AgentProtocol.mapJSON(for: map)
        let root = json["root"] as? [String: Any]
        XCTAssertNil(root?["formulaResult"])
    }
}
