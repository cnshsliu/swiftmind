import XCTest
@testable import SwiftMindCore

final class FormulaParserTests: XCTestCase {

    // MARK: - Atoms

    func testLiterals() throws {
        XCTAssertEqual(try FormulaParser.parse("42"), .number(42))
        XCTAssertEqual(try FormulaParser.parse("3.14"), .number(3.14))
        XCTAssertEqual(try FormulaParser.parse("\"hello\""), .string("hello"))
        XCTAssertEqual(try FormulaParser.parse("true"), .bool(true))
        XCTAssertEqual(try FormulaParser.parse("false"), .bool(false))
    }

    func testAttribute() throws {
        XCTAssertEqual(try FormulaParser.parse("attr(\"cost\")"), .attribute(name: "cost"))
    }

    func testParenthesizedExpression() throws {
        XCTAssertEqual(try FormulaParser.parse("(42)"), .number(42))
        XCTAssertEqual(
            try FormulaParser.parse("(1 + 2)"),
            .binary(.add, .number(1), .number(2))
        )
    }

    // MARK: - Aggregates and if

    func testSumAggregate() throws {
        XCTAssertEqual(
            try FormulaParser.parse("sum(children, attr: \"cost\")"),
            .aggregate(kind: .sum, attribute: "cost")
        )
    }

    func testAllAggregateKinds() throws {
        for kind: AggregateKind in [.sum, .avg, .min, .max] {
            XCTAssertEqual(
                try FormulaParser.parse("\(kind.rawValue)(children, attr: \"x\")"),
                .aggregate(kind: kind, attribute: "x")
            )
        }
        XCTAssertEqual(
            try FormulaParser.parse("count(children)"),
            .aggregate(kind: .count, attribute: nil)
        )
        XCTAssertEqual(
            try FormulaParser.parse("progress()"),
            .aggregate(kind: .progress, attribute: nil)
        )
    }

    func testConditional() throws {
        XCTAssertEqual(
            try FormulaParser.parse("if(attr(\"done\") == true, 1, 0)"),
            .conditional(
                condition: .binary(.equal, .attribute(name: "done"), .bool(true)),
                then: .number(1),
                else: .number(0)
            )
        )
    }

    // MARK: - Precedence

    func testMultiplicationBindsTighterThanAddition() throws {
        XCTAssertEqual(
            try FormulaParser.parse("1 + 2 * 3"),
            .binary(.add, .number(1), .binary(.multiply, .number(2), .number(3)))
        )
    }

    func testLeftAssociativity() throws {
        XCTAssertEqual(
            try FormulaParser.parse("10 - 4 - 3"),
            .binary(.subtract, .binary(.subtract, .number(10), .number(4)), .number(3))
        )
    }

    func testComparisonLooserThanArithmetic() throws {
        XCTAssertEqual(
            try FormulaParser.parse("1 + 2 > 3"),
            .binary(.greater, .binary(.add, .number(1), .number(2)), .number(3))
        )
    }

    func testAndBindsTighterThanOr() throws {
        XCTAssertEqual(
            try FormulaParser.parse("attr(\"a\") and attr(\"b\") or attr(\"c\")"),
            .binary(
                .or,
                .binary(.and, .attribute(name: "a"), .attribute(name: "b")),
                .attribute(name: "c")
            )
        )
    }

    func testUnaryBindsTighterThanMultiplication() throws {
        XCTAssertEqual(
            try FormulaParser.parse("-attr(\"x\") * 2"),
            .binary(.multiply, .unary(.negate, .attribute(name: "x")), .number(2))
        )
    }

    func testNotBindsTighterThanComparison() throws {
        XCTAssertEqual(
            try FormulaParser.parse("not attr(\"done\") == true"),
            .binary(.equal, .unary(.not, .attribute(name: "done")), .bool(true))
        )
    }

    func testDoubleNegation() throws {
        XCTAssertEqual(try FormulaParser.parse("--5"), .unary(.negate, .unary(.negate, .number(5))))
    }

    func testComplexFormula() throws {
        let ast = try FormulaParser.parse(
            "if(count(children) > 0 and progress() >= 0.5, sum(children, attr: \"cost\") * 1.2, 0)"
        )
        XCTAssertEqual(
            ast,
            .conditional(
                condition: .binary(
                    .and,
                    .binary(.greater, .aggregate(kind: .count, attribute: nil), .number(0)),
                    .binary(.greaterOrEqual, .aggregate(kind: .progress, attribute: nil), .number(0.5))
                ),
                then: .binary(.multiply, .aggregate(kind: .sum, attribute: "cost"), .number(1.2)),
                else: .number(0)
            )
        )
    }

    // MARK: - Errors

    func testEmptyInputThrows() {
        assertParseError("", containing: "unexpected end")
    }

    func testTrailingTokensThrow() {
        assertParseError("1 2", containing: "after complete expression")
    }

    func testUnclosedParenThrows() {
        assertParseError("(1 + 2", containing: "expected \")\"")
    }

    func testUnexpectedClosingParenThrows() {
        assertParseError("1 + )", containing: "unexpected \")\"")
    }

    func testUnknownIdentifierThrows() {
        assertParseError("foo(1)", containing: "unknown identifier \"foo\"")
    }

    func testSumRequiresAttrLabel() {
        assertParseError("sum(children, \"cost\")", containing: "expected \"attr\"")
    }

    func testSumRequiresChildrenScope() {
        assertParseError("sum(all, attr: \"cost\")", containing: "expected \"children\"")
    }

    func testCountRejectsArguments() {
        assertParseError("count(children, attr: \"x\")", containing: "expected \")\"")
    }

    func testIfRequiresThreeArguments() {
        assertParseError("if(true, 1)", containing: "expected \",\"")
    }

    func testAttrRequiresString() {
        assertParseError("attr(cost)", containing: "expected a quoted string")
    }

    func testErrorCarriesPosition() {
        do {
            _ = try FormulaParser.parse("1 + foo")
            XCTFail("expected error")
        } catch let error as FormulaError {
            XCTAssertGreaterThanOrEqual(error.position, 4)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    // MARK: - Helpers

    private func assertParseError(_ source: String, containing fragment: String, file: StaticString = #filePath, line: UInt = #line) {
        do {
            _ = try FormulaParser.parse(source)
            XCTFail("expected error containing \"\(fragment)\"", file: file, line: line)
        } catch let error as FormulaError {
            XCTAssertTrue(
                error.message.contains(fragment),
                "error \"\(error.message)\" does not contain \"\(fragment)\"",
                file: file,
                line: line
            )
        } catch {
            XCTFail("wrong error type: \(error)", file: file, line: line)
        }
    }
}
