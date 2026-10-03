import XCTest
@testable import SwiftMindCore

final class MindMapBundleTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mindmap-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testChildrenSkipAssetsAndForeignHTML() throws {
        let vault = try makeDir("Vault")
        try writeMap(vault.appendingPathComponent("Notes.swiftmind.html"), body: "notes")
        try Data("hi".utf8).write(to: vault.appendingPathComponent("index.html"))
        let assets = vault.appendingPathComponent("Notes.swiftmind.assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Data("png".utf8).write(to: assets.appendingPathComponent("img-1.png"))
        try makeDir("Vault/Topics")
        let names = MindMapBundle.children(of: vault).map { "\($0.kind)-\($0.url.lastPathComponent)" }
        XCTAssertEqual(Set(names), ["folder-Topics", "map-Notes.swiftmind.html"])
    }

    func testSymlinkCycleIsFinite() throws {
        let vault = try makeDir("Loop")
        let inner = try makeDir("Loop/inner")
        try FileManager.default.createSymbolicLink(
            at: inner.appendingPathComponent("back"),
            withDestinationURL: vault
        )
        let folders = MindMapBundle.destinationFolders(vaults: [vault])
        XCTAssertLessThan(folders.count, 8)
        XCTAssertTrue(folders.contains { $0.title == "Loop" })
        XCTAssertTrue(folders.contains { $0.title == "Loop / inner" })
    }

    func testCopyCarriesAssetsAndKeepsTheSource() throws {
        let sourceDir = try makeDir("A")
        let destDir = try makeDir("B")
        let map = sourceDir.appendingPathComponent("Plan.swiftmind.html")
        try writeMap(map, body: "plan-body")
        try writeAsset(for: map, name: "img-1.png", bytes: Data("pic".utf8))
        let dest = try MindMapBundle.transfer(mapURL: map, to: destDir, baseName: "Plan", move: false)
        XCTAssertEqual(dest.lastPathComponent, "Plan.swiftmind.html")
        XCTAssertTrue(FileManager.default.fileExists(atPath: map.path))
        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "plan-body")
        let copiedPic = MindMapBundle.assetsURL(for: dest).appendingPathComponent("img-1.png")
        XCTAssertEqual(try Data(contentsOf: copiedPic), Data("pic".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: MindMapBundle.assetsURL(for: map).path))
    }

    func testMoveRenamesTheFileAndTheAssetsFolder() throws {
        let dir = try makeDir("Vault")
        let map = dir.appendingPathComponent("Old.swiftmind.html")
        try writeMap(map, body: "old")
        try writeAsset(for: map, name: "img-1.png", bytes: Data("pic".utf8))
        let dest = try MindMapBundle.transfer(mapURL: map, to: dir, baseName: "New", move: true)
        XCTAssertEqual(dest.lastPathComponent, "New.swiftmind.html")
        XCTAssertFalse(FileManager.default.fileExists(atPath: map.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: MindMapBundle.assetsURL(for: map).path))
        XCTAssertEqual(try Data(contentsOf: MindMapBundle.assetsURL(for: dest).appendingPathComponent("img-1.png")), Data("pic".utf8))
    }

    func testCopyIntoTheSameFolderGetsANumber() throws {
        let dir = try makeDir("Vault")
        let map = dir.appendingPathComponent("Plan.swiftmind.html")
        try writeMap(map, body: "v1")
        try writeAsset(for: map, name: "img.png", bytes: Data([1]))
        let dest = try MindMapBundle.transfer(mapURL: map, to: dir, baseName: "Plan", move: false)
        XCTAssertEqual(dest.lastPathComponent, "Plan 2.swiftmind.html")
        XCTAssertTrue(FileManager.default.fileExists(atPath: MindMapBundle.assetsURL(for: dest).appendingPathComponent("img.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: map.path))
    }

    func testMoveToTheSamePathIsANoOp() throws {
        let dir = try makeDir("Vault")
        let map = dir.appendingPathComponent("Plan.swiftmind.html")
        try writeMap(map, body: "v1")
        let dest = try MindMapBundle.transfer(mapURL: map, to: dir, baseName: "Plan", move: true)
        XCTAssertEqual(MindMapBundle.canonicalPath(dest), MindMapBundle.canonicalPath(map))
        XCTAssertTrue(FileManager.default.fileExists(atPath: map.path))
    }

    func testEmptyAndDotDotNamesAreRejected() throws {
        let dir = try makeDir("Vault")
        let map = dir.appendingPathComponent("Plan.swiftmind.html")
        try writeMap(map, body: "v1")
        XCTAssertThrowsError(try MindMapBundle.transfer(mapURL: map, to: dir, baseName: "   ", move: false)) { error in
            XCTAssertEqual(error as? MindMapBundle.Failure, .emptyName)
        }
        XCTAssertThrowsError(try MindMapBundle.transfer(mapURL: map, to: dir, baseName: "..", move: true)) { error in
            XCTAssertEqual(error as? MindMapBundle.Failure, .unsafeName)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: map.path))
    }

    func testSlashInTheNameCannotEscapeTheFolder() throws {
        let dir = try makeDir("Vault")
        let outside = try makeDir("Outside")
        let map = dir.appendingPathComponent("Plan.swiftmind.html")
        try writeMap(map, body: "v1")
        let dest = try MindMapBundle.transfer(mapURL: map, to: dir, baseName: "../Outside/Pwn", move: true)
        XCTAssertTrue(dest.path.hasPrefix(dir.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("Pwn.swiftmind.html").path))
    }

    func testCopyIntoOwnAssetsFolderIsRejected() throws {
        let dir = try makeDir("Vault")
        let map = dir.appendingPathComponent("Plan.swiftmind.html")
        try writeMap(map, body: "v1")
        let assets = try writeAsset(for: map, name: "img.png", bytes: Data([1]))
        XCTAssertThrowsError(try MindMapBundle.transfer(mapURL: map, to: assets, baseName: "Nested", move: false)) { error in
            XCTAssertEqual(error as? MindMapBundle.Failure, .destinationInsideAssets)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: map.path))
    }

    func testExistingDestinationAssetsLeavesTheSourceUntouched() throws {
        let sourceDir = try makeDir("A")
        let destDir = try makeDir("B")
        let map = sourceDir.appendingPathComponent("Plan.swiftmind.html")
        try writeMap(map, body: "v1")
        try writeAsset(for: map, name: "img.png", bytes: Data([1]))
        let blocker = destDir.appendingPathComponent("Plan.swiftmind.assets")
        try Data("not-a-dir".utf8).write(to: blocker)
        XCTAssertThrowsError(try MindMapBundle.transfer(mapURL: map, to: destDir, baseName: "Plan", move: true)) { error in
            XCTAssertEqual(error as? MindMapBundle.Failure, .assetsDestinationExists)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("Plan.swiftmind.html").path))
        XCTAssertEqual(try String(contentsOf: map, encoding: .utf8), "v1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: MindMapBundle.assetsURL(for: map).path))
    }

    func testStripsAPastedExtensionAndColon() {
        XCTAssertEqual(MindMapBundle.sanitizedBaseName("  Foo.swiftmind.html "), "Foo")
        XCTAssertEqual(MindMapBundle.sanitizedBaseName("a/b:c"), "a-b-c")
    }


    // ---- Atomicity (Lucas): a move must never end half-done ----

    func testMoveLeavesNoSourceWhenAssetsAbsent() throws {
        let src = try makeDir("src").appendingPathComponent("A.swiftmind.html")
        try writeMap(src, body: "v1")
        let dst = try makeDir("dst")
        let out = try MindMapBundle.transfer(mapURL: src, to: dst, baseName: "B", move: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path), "source html must be GONE after a clean move")
    }

    func testMoveWithAssetsIsAllOrNothing() throws {
        let src = try makeDir("src").appendingPathComponent("A.swiftmind.html")
        try writeMap(src, body: "v1")
        try writeAsset(for: src, name: "img.png", bytes: Data([1, 2, 3]))
        let dst = try makeDir("dst")
        let out = try MindMapBundle.transfer(mapURL: src, to: dst, baseName: "B", move: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: MindMapBundle.assetsURL(for: out).appendingPathComponent("img.png").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path), "A.html must not survive")
        XCTAssertFalse(FileManager.default.fileExists(atPath: MindMapBundle.assetsURL(for: src).path), "A assets must not survive")
    }

    func testMissingSourceThrowsAndTouchesNothing() throws {
        let dst = try makeDir("dst")
        let ghost = root.appendingPathComponent("ghost.swiftmind.html")
        XCTAssertThrowsError(try MindMapBundle.transfer(mapURL: ghost, to: dst, baseName: "B", move: true))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dst.path), [], "nothing may be created when the source is missing")
    }

    func testAssetsDestinationCollisionRollsBackTheHtml() throws {
        let src = try makeDir("src").appendingPathComponent("A.swiftmind.html")
        try writeMap(src, body: "v1")
        try writeAsset(for: src, name: "img.png", bytes: Data([1]))
        let dst = try makeDir("dst")
        // Pre-create B's assets dir -> the transfer must refuse AFTER the
        // preflight (before any item moves), source fully intact.
        let b = dst.appendingPathComponent("B.swiftmind.html")
        try FileManager.default.createDirectory(at: MindMapBundle.assetsURL(for: b), withIntermediateDirectories: true)
        XCTAssertThrowsError(try MindMapBundle.transfer(mapURL: src, to: dst, baseName: "B", move: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path), "source html intact after refusal")
        XCTAssertTrue(FileManager.default.fileExists(atPath: MindMapBundle.assetsURL(for: src).appendingPathComponent("img.png").path), "source assets intact after refusal")
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.path), "no half-created destination html")
    }

    private func makeDir(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeMap(_ url: URL, body: String) throws {
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func writeAsset(for map: URL, name: String, bytes: Data) throws -> URL {
        let dir = MindMapBundle.assetsURL(for: map)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(name)
        try bytes.write(to: file)
        return dir
    }
}
