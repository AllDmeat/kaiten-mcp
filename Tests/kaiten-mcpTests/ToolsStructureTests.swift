import Foundation
import XCTest

final class ToolsStructureTests: XCTestCase {
  func testMainSwiftIsBootstrapOnly() throws {
    let sourceRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let mainFile = sourceRoot.appendingPathComponent("Sources/kaiten-mcp/main.swift")
    let content = try String(contentsOf: mainFile, encoding: .utf8)
    let lineCount = content.split(separator: "\n", omittingEmptySubsequences: false).count
    XCTAssertLessThan(
      lineCount,
      600,
      "main.swift should stay as bootstrap/registration only; move tool definitions and handlers into Tools/* files."
    )
  }
}
