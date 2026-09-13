import XCTest
@testable import SwiftMindCore

final class PreferencesMapTests: XCTestCase {
    func testViewportRoundTripThroughHTML() throws {
        var prefs = PreferencesMap.makeEmpty()
        let vp = CanvasViewport(scale: 1.25, offset: Point2D(x: 40, y: -12))
        PreferencesMap.upsertViewport(mapID: "m_abc", title: "Demo", viewport: vp, into: &prefs)
        let html = try HTMLCodec.encode(prefs, includeSkin: false)
        let decoded = try HTMLCodec.decode(html)
        let restored = PreferencesMap.viewport(forMapID: "m_abc", in: decoded)
        XCTAssertEqual(restored?.scale ?? 0, 1.25, accuracy: 0.0001)
        XCTAssertEqual(restored?.offset.x ?? 0, 40, accuracy: 0.0001)
        XCTAssertEqual(restored?.offset.y ?? 0, -12, accuracy: 0.0001)
    }

    func testUpsertReplacesSameMapID() {
        var prefs = PreferencesMap.makeEmpty()
        PreferencesMap.upsertViewport(mapID: "m_x", title: "A", viewport: CanvasViewport(scale: 2), into: &prefs)
        PreferencesMap.upsertViewport(mapID: "m_x", title: "B", viewport: CanvasViewport(scale: 0.5), into: &prefs)
        let view = prefs.node(id: PreferencesMap.viewNodeID)
        XCTAssertEqual(view?.children.count, 1)
        XCTAssertEqual(view?.children.first?.text, "B")
        XCTAssertEqual(PreferencesMap.viewport(forMapID: "m_x", in: prefs)?.scale ?? 0, 0.5, accuracy: 0.0001)
    }
}
