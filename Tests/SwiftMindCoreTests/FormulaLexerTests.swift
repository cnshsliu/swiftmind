import XCTest
@testable import SwiftMindCore

final class FormulaLexerTests: XCTestCase {

    private func kinds(_ source: String) throws -> [FormulaToken.Kind] {
        try FormulaLexer.tokenize(source).map(\.kind)
    }

    func testLiteralsAndIdentifiers() throws {
        XCTAssertEqual(
            try kinds("42 3.14 \"cost\" status _x"),
            [.number(42), .number(3.14), .string("cost"), .identifier("status"), .identifier("_x")]
        )
    }

    func testPunctuationAndArithmeticOperators() throws {
        XCTAssertEqual(
            try kinds("(a, b: c) + - * / %"),
            [
                .lparen, .identifier("a"), .comma, .identifier("b"), .colon,
                .identifier("c"), .rparen,
                .operator("+"), .operator("-"), .operator("*"), .operator("/"), .operator("%"),
            ]
        )
    }

    func testComparisonOperators() throws {
        XCTAssertEqual(
            try kinds("== != < <= > >="),
            [.operator("=="), .operator("!="), .operator("<"), .operator("<="), .operator(">"), .operator(">=")]
        )
    }

    func testWhitespaceIsSkipped() throws {
        XCTAssertEqual(try kinds("  1\t+\n2 "), [.number(1), .operator("+"), .number(2)])
    }

    func testStringEscapes() throws {
        XCTAssertEqual(try kinds("\"say \\\"hi\\\" \\\\ ok\""), [.string("say \"hi\" \\ ok")])
    }

    func testUnterminatedStringThrows() {
        XCTAssertThrowsError(try kinds("\"oops")) { error in
            guard let err = error as? FormulaError else { return XCTFail("wrong error type") }
            XCTAssertTrue(err.message.contains("unterminated string"))
            XCTAssertEqual(err.position, 0)
        }
    }

    func testUnsupportedEscapeThrows() {
        XCTAssertThrowsError(try kinds("\"a\\nb\"")) { error in
            guard let err = error as? FormulaError else { return XCTFail("wrong error type") }
            XCTAssertTrue(err.message.contains("unsupported escape"))
        }
    }

    func testLoneEqualsThrows() {
        XCTAssertThrowsError(try kinds("1 = 2")) { error in
            guard let err = error as? FormulaError else { return XCTFail("wrong error type") }
            XCTAssertTrue(err.message.contains("=="))
        }
    }

    func testUnexpectedCharacterThrows() {
        XCTAssertThrowsError(try kinds("1 @ 2")) { error in
            guard let err = error as? FormulaError else { return XCTFail("wrong error type") }
            XCTAssertTrue(err.message.contains("unexpected character"))
            XCTAssertEqual(err.position, 2)
        }
    }

    func testNumberStopsBeforeSecondDot() {
        // "1.2.3" lexes "1.2" then hits "." which is not a valid token start
        XCTAssertThrowsError(try kinds("1.2.3"))
    }

    func testEmptySource() throws {
        XCTAssertEqual(try kinds(""), [])
        XCTAssertEqual(try kinds("   "), [])
    }
}
