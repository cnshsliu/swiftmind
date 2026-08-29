import XCTest
@testable import SwiftMindCore

/// Hardening suite: codec fuzz round-trips, undo/redo stress, large-map guardrails.
final class HardeningTests: XCTestCase {

    /// SplitMix64 — deterministic, so any failure reproduces from the printed seed.
    struct SeededRNG: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { self.state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func percent() -> UInt64 { next() % 100 }
    }

    // Lone "\r" round-trips via &#13;. "\r\n" is excluded: Foundation's
    // XMLParser normalizes the pair to "\n" even across character references.
    private static let hostileFragments = [
        "<b>&\"'</b>",
        "emoji 🧠🚀✨",
        "中文标题测试",
        "日本語のテキスト",
        "line1\nline2\nline3",
        "tab\there",
        "carriage\rreturn",
        "",
        "   ",
        "quotes \"double\" 'single' <angle> &amp;",
        "🧪🧬🔬",
        String(repeating: "Long&<>\"'中文🧠", count: 25),
        "x < y && y > z",
    ]

    private static let formulaPool = [
        "count(children)",
        "sum(children, attr: \"x\")",
        "avg(children, attr: \"cost\")",
        "min(children, attr: \"x\")",
        "max(children, attr: \"x\")",
        "progress()",
        "attr(\"x\")",
    ]

    private static let styleNamePool = ["topic", "important", "note"]

    private func hostileText(_ rng: inout SeededRNG) -> String {
        let count = Int.random(in: 1...3, using: &rng)
        return (0..<count)
            .map { _ in Self.hostileFragments.randomElement(using: &rng)! }
            .joined(separator: rng.next() % 2 == 0 ? " " : "")
    }

    // MARK: - Random map generation

    private func makeRandomNode(
        rng: inout SeededRNG,
        counter: inout Int,
        depth: Int,
        maxDepth: Int,
        budget: inout Int
    ) -> Node {
        counter += 1
        budget -= 1
        let myIndex = counter

        var links: [NodeLink] = []
        if rng.percent() < 25 {
            for i in 0...Int.random(in: 0...1, using: &rng) {
                links.append(.url(URL(string: "https://example.com/path/\(myIndex)/\(i)?q=\(rng.next() % 1000)")!))
            }
        }

        var icons: [NodeIcon] = []
        if rng.percent() < 25 {
            for _ in 0...Int.random(in: 0...2, using: &rng) {
                icons.append(NodeIcon.catalog.randomElement(using: &rng)!)
            }
        }

        var attributes: [NodeAttribute] = []
        if rng.percent() < 30 {
            let names = ["x", "cost", "priority", "status", "owner", "tag"]
            for _ in 0...Int.random(in: 0...2, using: &rng) {
                attributes.append(NodeAttribute(
                    name: names.randomElement(using: &rng)!,
                    value: hostileText(&rng)
                ))
            }
        }

        var children: [Node] = []
        if depth < maxDepth, budget > 0 {
            for _ in 0...Int.random(in: 0...3, using: &rng) where budget > 0 {
                children.append(makeRandomNode(
                    rng: &rng, counter: &counter, depth: depth + 1, maxDepth: maxDepth, budget: &budget
                ))
            }
        }

        return Node(
            id: NodeID(rawValue: "h_\(myIndex)"),
            text: hostileText(&rng),
            noteMarkdown: rng.percent() < 30 ? hostileText(&rng) : "",
            links: links,
            icons: icons,
            attributes: attributes,
            styleName: rng.percent() < 25 ? Self.styleNamePool.randomElement(using: &rng)! : nil,
            formula: rng.percent() < 15 ? Self.formulaPool.randomElement(using: &rng)! : nil,
            isFolded: rng.percent() < 20,
            side: [.auto, .left, .right].randomElement(using: &rng)!,
            style: .default,
            positionPin: rng.percent() < 20
                ? Point2D(
                    x: Double(Int.random(in: -500...500, using: &rng)) + 0.5,
                    y: Double(Int.random(in: -500...500, using: &rng)) + 0.5
                )
                : nil,
            children: children
        )
    }

    private func makeRandomMap(seed: UInt64) -> MindMap {
        var rng = SeededRNG(seed: seed)
        var map = MindMap.makeEmpty(title: hostileText(&rng))
        var counter = 0
        var budget = Int.random(in: 20...60, using: &rng)
        let maxDepth = Int.random(in: 2...5, using: &rng)
        map.root = makeRandomNode(
            rng: &rng, counter: &counter, depth: 0, maxDepth: maxDepth, budget: &budget
        )
        // Decode auto-registers attribute names found on nodes; mirror that here
        // so the original map is comparable to its round-tripped form.
        registerAttributes(in: &map)
        return map
    }

    private func registerAttributes(in map: inout MindMap) {
        func walk(_ node: Node) {
            for attr in node.attributes { map.attributeRegistry.ensureRegistered(attr.name) }
            node.children.forEach(walk)
        }
        walk(map.root)
    }

    private func countNodes(_ node: Node) -> Int {
        1 + node.children.reduce(0) { $0 + countNodes($1) }
    }

    private func allIDs(_ node: Node) -> [NodeID] {
        [node.id] + node.children.flatMap(allIDs)
    }

    // MARK: - 1. HTML codec round-trip robustness

    func testHTMLRoundTripHostileRandomMaps() throws {
        for seed: UInt64 in 1...25 {
            let map = makeRandomMap(seed: seed)
            let html = try HTMLCodec.encode(map, includeSkin: false)
            let decoded = try HTMLCodec.decode(html)
            XCTAssertEqual(decoded, map, "round-trip mismatch for seed \(seed)")
        }
    }

    func testHTMLEncodeIdempotentRandomMaps() throws {
        for seed: UInt64 in 26...40 {
            let map = makeRandomMap(seed: seed)
            let html1 = try HTMLCodec.encode(map, includeSkin: false)
            let html2 = try HTMLCodec.encode(HTMLCodec.decode(html1), includeSkin: false)
            XCTAssertEqual(html2, html1, "encode not idempotent for seed \(seed)")
        }
    }

    // MARK: - 2. Undo/redo stress

    func testUndoRedoStressRandomCommandSequence() throws {
        var rng = SeededRNG(seed: 0xC0FFEE)
        let store = MapStore(map: MindMap.makeEmpty(title: "Stress"))
        let initialMap = store.map
        var textCounter = 0

        for step in 0..<200 {
            let ids = allIDs(store.map.root)
            let nonRoot = ids.filter { $0 != store.map.root.id }
            switch Int(rng.next() % 7) {
            case 0: // insert child under an existing node
                let parent = ids.randomElement(using: &rng)!
                textCounter += 1
                try store.dispatch(InsertChildCommand(parentID: parent, text: "n\(textCounter)"))
            case 1: // insert sibling next to a non-root node
                guard let ref = nonRoot.randomElement(using: &rng) else { continue }
                textCounter += 1
                try store.dispatch(InsertSiblingCommand(siblingID: ref, text: "s\(textCounter)"))
            case 2: // delete a non-root node
                guard let victim = nonRoot.randomElement(using: &rng) else { continue }
                try store.dispatch(DeleteNodesCommand(nodeIDs: [victim]))
            case 3: // move a non-root node under a node outside its own subtree
                guard let nodeID = nonRoot.randomElement(using: &rng),
                      let moving = store.map.node(id: nodeID) else { continue }
                let subtree = Set(allIDs(moving))
                let targets = ids.filter { !subtree.contains($0) }
                guard let newParent = targets.randomElement(using: &rng),
                      let parentNode = store.map.node(id: newParent) else { continue }
                let index = Int.random(in: 0...parentNode.children.count, using: &rng)
                try store.dispatch(MoveNodeCommand(nodeID: nodeID, newParentID: newParent, index: index))
            case 4: // set text
                let id = ids.randomElement(using: &rng)!
                try store.dispatch(SetTextCommand(nodeID: id, newText: hostileText(&rng)))
            case 5: // toggle fold
                let id = ids.randomElement(using: &rng)!
                try store.dispatch(SetFoldedCommand(nodeID: id, isFolded: rng.next() % 2 == 0))
            default: // set or clear pin
                let id = ids.randomElement(using: &rng)!
                let pin: Point2D? = rng.next() % 4 == 0
                    ? nil
                    : Point2D(
                        x: Double(Int(rng.next() % 1000)) - 500,
                        y: Double(Int(rng.next() % 1000)) - 500
                    )
                try store.dispatch(SetPinCommand(nodeID: id, positionPin: pin))
            }
            // Shake the stacks: undo 5, redo 5 every 25 commands.
            if step % 25 == 24 {
                for _ in 0..<5 where store.canUndo { try store.undo() }
                for _ in 0..<5 where store.canRedo { try store.redo() }
            }
        }

        let finalMap = store.map
        while store.canUndo { try store.undo() }
        XCTAssertEqual(store.map, initialMap, "undo-all did not restore the initial map")
        while store.canRedo { try store.redo() }
        XCTAssertEqual(store.map, finalMap, "redo-all did not reproduce the final map")
    }

    // MARK: - 3. Large-map performance guardrails

    /// 10,001 nodes: 25 wide branches (199 leaves each) + 25 deep chains (200 deep).
    private func makeTenThousandNodeMap() -> MindMap {
        var map = MindMap.makeEmpty(title: "10k")
        var counter = 0
        func nextID() -> NodeID {
            counter += 1
            return NodeID(rawValue: "p_\(counter)")
        }
        map.root.children = (0..<50).map { b in
            if b % 2 == 0 {
                let leaves = (0..<199).map { _ in Node(id: nextID(), text: "leaf") }
                return Node(id: nextID(), text: "wide \(b)", children: leaves)
            } else {
                var chain = Node(id: nextID(), text: "deep \(b) tip")
                for _ in 0..<199 {
                    chain = Node(id: nextID(), text: "deep \(b)", children: [chain])
                }
                return chain
            }
        }
        return map
    }

    func testLayoutTenThousandNodesUnderBudget() {
        let map = makeTenThousandNodeMap()
        XCTAssertEqual(countNodes(map.root), 10001)
        let engine = LayoutEngine()

        let start = Date()
        let snapshot = engine.layout(map: map, selection: SelectionState())
        let elapsed = Date().timeIntervalSince(start)

        print("GUARDRAIL layout 10001 nodes: \(String(format: "%.3f", elapsed))s")
        XCTAssertEqual(snapshot.nodes.count, 10001)
        XCTAssertLessThan(elapsed, 2.0, "Layout regression: 10k nodes should layout under 2s")
    }

    func testEncodeDecodeRoundTripTenThousandNodes() throws {
        let map = makeTenThousandNodeMap()

        let start = Date()
        let html = try HTMLCodec.encode(map, includeSkin: false)
        let decoded = try HTMLCodec.decode(html)
        let elapsed = Date().timeIntervalSince(start)

        print("GUARDRAIL codec round trip 10001 nodes: \(String(format: "%.3f", elapsed))s")
        XCTAssertEqual(countNodes(decoded.root), countNodes(map.root))
        XCTAssertLessThan(elapsed, 5.0, "Codec regression: 10k-node round trip should finish under 5s")
    }
}
