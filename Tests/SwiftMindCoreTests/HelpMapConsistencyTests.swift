import XCTest
@testable import SwiftMindCore

/// README/help numbers and shortcuts must stay true of the ops file (YOINK figures.py idea).
final class HelpMapConsistencyTests: XCTestCase {
    func testHelpMapOpsContainWhySwiftMindAndCoreShortcuts() throws {
        let ops = try String(contentsOf: helpOpsURL(), encoding: .utf8)
        for needle in [
            "Why SwiftMind",
            "n_help_why_html",
            "n_help_why_agents",
            "⌘T child",
            "⌘Z undo",
            "⌘F searches",
            "⌘K command palette",
            "⌘+ / ⌘- / ⌘0 / ⌘9 zoom",
            "orphan",
            "n_help_why_orphan",
            "n_help_why_dangle",
        ] {
            XCTAssertTrue(ops.contains(needle), "help-map.ops.json missing \(needle)")
        }
    }

    func testREADMEMentionsOpenHTMLAndAgentCLI() throws {
        let readme = try String(contentsOf: repoRoot().appendingPathComponent("README.md"), encoding: .utf8)
        XCTAssertTrue(readme.contains(".swiftmind.html"))
        XCTAssertTrue(readme.contains("swiftmind mcp") || readme.contains("`swiftmind mcp`"))
        XCTAssertTrue(readme.contains("⌘+"))
    }

    private func helpOpsURL() -> URL {
        repoRoot()
            .appendingPathComponent("Apps/SwiftMindMac/SwiftMindMac/Resources/help-map.ops.json")
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
