import XCTest
@testable import SwiftMindCore

final class FormulaEvaluatorTests: XCTestCase {

    // MARK: - Helpers

    private func node(
        _ text: String = "n",
        attributes: [NodeAttribute] = [],
        icons: [NodeIcon] = [],
        children: [Node] = []
    ) -> Node {
        Node(text: text, icons: icons, attributes: attributes, children: children)
    }

    private func eval(_ source: String, on node: Node) -> FormulaValue {
        FormulaEvaluator.evaluate(source: source, on: node)
    }

    private func assertError(_ source: String, on node: Node, containing fragment: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case .error(let message) = eval(source, on: node) else {
            return XCTFail("expected error containing \"\(fragment)\"", file: file, line: line)
        }
        XCTAssertTrue(message.contains(fragment), "\"\(message)\" does not contain \"\(fragment)\"", file: file, line: line)
    }

    // MARK: - Literals and arithmetic

    func testLiterals() {
        let n = node()
        XCTAssertEqual(eval("42", on: n), .number(42))
        XCTAssertEqual(eval("\"hi\"", on: n), .string("hi"))
        XCTAssertEqual(eval("true", on: n), .bool(true))
    }

    func testArithmetic() {
        let n = node()
        XCTAssertEqual(eval("1 + 2 * 3", on: n), .number(7))
        XCTAssertEqual(eval("(1 + 2) * 3", on: n), .number(9))
        XCTAssertEqual(eval("10 / 4", on: n), .number(2.5))
        XCTAssertEqual(eval("10 % 4", on: n), .number(2))
        XCTAssertEqual(eval("-3 + 1", on: n), .number(-2))
    }

    func testDivisionByZero() {
        assertError("1 / 0", on: node(), containing: "division by zero")
        assertError("1 % 0", on: node(), containing: "division by zero")
    }

    func testArithmeticOnBoolFails() {
        assertError("true + 1", on: node(), containing: "cannot use a bool in arithmetic")
    }

    func testNumericStringCoercionInArithmetic() {
        let n = node(attributes: [NodeAttribute(name: "cost", value: "10")])
        XCTAssertEqual(eval("attr(\"cost\") * 2", on: n), .number(20))
    }

    // MARK: - Attributes

    func testAttributeSmartCoercion() {
        let n = node(attributes: [
            NodeAttribute(name: "cost", value: "12.5"),
            NodeAttribute(name: "done", value: "true"),
            NodeAttribute(name: "owner", value: "lucas"),
        ])
        XCTAssertEqual(eval("attr(\"cost\")", on: n), .number(12.5))
        XCTAssertEqual(eval("attr(\"done\")", on: n), .bool(true))
        XCTAssertEqual(eval("attr(\"owner\")", on: n), .string("lucas"))
    }

    func testUnknownAttribute() {
        assertError("attr(\"missing\")", on: node(), containing: "unknown attribute \"missing\"")
    }

    // MARK: - Comparison and boolean

    func testEquality() {
        let n = node(attributes: [NodeAttribute(name: "done", value: "true")])
        XCTAssertEqual(eval("attr(\"done\") == true", on: n), .bool(true))
        XCTAssertEqual(eval("1 == 1.0", on: n), .bool(true))
        XCTAssertEqual(eval("\"a\" != \"b\"", on: n), .bool(true))
        XCTAssertEqual(eval("\"a\" == true", on: n), .bool(false))
    }

    func testOrdering() {
        let n = node()
        XCTAssertEqual(eval("2 > 1", on: n), .bool(true))
        XCTAssertEqual(eval("2 <= 1", on: n), .bool(false))
        XCTAssertEqual(eval("\"apple\" < \"banana\"", on: n), .bool(true))
    }

    func testIncomparableTypesError() {
        assertError("true > 1", on: node(), containing: "cannot compare")
    }

    func testBooleanOps() {
        let n = node()
        XCTAssertEqual(eval("true and false", on: n), .bool(false))
        XCTAssertEqual(eval("true or false", on: n), .bool(true))
        XCTAssertEqual(eval("not false", on: n), .bool(true))
        assertError("1 and true", on: n, containing: "and expects a bool")
    }

    // MARK: - Conditional

    func testIfSelectsBranch() {
        let n = node()
        XCTAssertEqual(eval("if(1 > 0, \"yes\", \"no\")", on: n), .string("yes"))
        XCTAssertEqual(eval("if(1 < 0, \"yes\", \"no\")", on: n), .string("no"))
    }

    func testIfIsLazy() {
        // The untaken branch would error (division by zero); it must not be evaluated.
        XCTAssertEqual(eval("if(true, 1, 1 / 0)", on: node()), .number(1))
        XCTAssertEqual(eval("if(false, 1 / 0, 2)", on: node()), .number(2))
    }

    func testIfRequiresBoolCondition() {
        assertError("if(1, 2, 3)", on: node(), containing: "condition must be a bool")
    }

    // MARK: - Aggregates

    func testSumCountAvgMinMax() {
        let n = node(children: [
            node("a", attributes: [NodeAttribute(name: "cost", value: "10")]),
            node("b", attributes: [NodeAttribute(name: "cost", value: "20")]),
            node("c"), // missing attr → skipped
        ])
        XCTAssertEqual(eval("sum(children, attr: \"cost\")", on: n), .number(30))
        XCTAssertEqual(eval("avg(children, attr: \"cost\")", on: n), .number(15))
        XCTAssertEqual(eval("min(children, attr: \"cost\")", on: n), .number(10))
        XCTAssertEqual(eval("max(children, attr: \"cost\")", on: n), .number(20))
        XCTAssertEqual(eval("count(children)", on: n), .number(3))
    }

    func testSumOverEmptyChildrenIsZero() {
        XCTAssertEqual(eval("sum(children, attr: \"cost\")", on: node()), .number(0))
        XCTAssertEqual(eval("count(children)", on: node()), .number(0))
    }

    func testAvgMinMaxOverNoValuesError() {
        let n = node(children: [node("a")])
        assertError("avg(children, attr: \"cost\")", on: n, containing: "no numeric values")
        assertError("min(children, attr: \"cost\")", on: n, containing: "no numeric values")
        assertError("max(children, attr: \"cost\")", on: n, containing: "no numeric values")
    }

    func testNonNumericAttributeInAggregateErrors() {
        let n = node(children: [
            node("bad child", attributes: [NodeAttribute(name: "cost", value: "free")]),
        ])
        assertError("sum(children, attr: \"cost\")", on: n, containing: "on \"bad child\" is not a number")
    }

    func testProgress() {
        let done = NodeIcon(id: "check")
        let n = node(children: [
            node("a", icons: [done]),
            node("b", children: [
                node("b1", icons: [done]),
                node("b2"),
            ]),
        ])
        // 2 of 4 descendants checked
        XCTAssertEqual(eval("progress()", on: n), .number(0.5))
    }

    func testProgressWithNoDescendantsIsZero() {
        XCTAssertEqual(eval("progress()", on: node()), .number(0))
    }

    // MARK: - Error propagation

    func testErrorsPropagateThroughTree() {
        let n = node()
        assertError("1 + attr(\"nope\") * 2", on: n, containing: "unknown attribute")
        assertError("not attr(\"nope\")", on: n, containing: "unknown attribute")
    }

    func testParseErrorBecomesValue() {
        assertError("1 +", on: node(), containing: "unexpected end")
    }

    func testDisplayText() {
        XCTAssertEqual(FormulaValue.number(1240).displayText, "1240")
        XCTAssertEqual(FormulaValue.number(2.5).displayText, "2.5")
        XCTAssertEqual(FormulaValue.bool(true).displayText, "true")
        XCTAssertEqual(FormulaValue.error("bad").displayText, "#ERR: bad")
    }
}
