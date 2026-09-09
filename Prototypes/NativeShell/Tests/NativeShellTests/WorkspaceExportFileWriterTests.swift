import Foundation
import XCTest

@testable import NativeShell

final class WorkspaceExportFileWriterTests: XCTestCase {
  func testWriteCreatesJSONFile() async throws {
    let directory = try makeDirectory()
    let destination = directory.appendingPathComponent("workspace.json")
    let data = Data("{\"formatVersion\":1}".utf8)

    try await WorkspaceExportFileWriter.write(data, to: destination)

    XCTAssertEqual(try Data(contentsOf: destination), data)
  }

  func testWriteAtomicallyReplacesRegularJSONFile() async throws {
    let directory = try makeDirectory()
    let destination = directory.appendingPathComponent("workspace.json")
    try Data("old".utf8).write(to: destination)
    let replacement = Data("new".utf8)

    try await WorkspaceExportFileWriter.write(replacement, to: destination)

    XCTAssertEqual(try Data(contentsOf: destination), replacement)
  }

  func testMissingParentFailsWithoutChangingExistingFile() async throws {
    let directory = try makeDirectory()
    let existing = directory.appendingPathComponent("existing.json")
    try Data("preserve".utf8).write(to: existing)
    let destination = directory.appendingPathComponent("missing/workspace.json")

    await assertThrowsAsyncError(
      try await WorkspaceExportFileWriter.write(Data("new".utf8), to: destination))

    XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "preserve")
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
  }

  func testNonDirectoryAncestorInspectionFailureDoesNotChangeAncestor() async throws {
    let directory = try makeDirectory()
    let ancestor = directory.appendingPathComponent("not-a-folder")
    try Data("preserve".utf8).write(to: ancestor)
    let destination = ancestor.appendingPathComponent("workspace.json")

    await assertThrowsAsyncError(
      try await WorkspaceExportFileWriter.write(Data("new".utf8), to: destination))

    XCTAssertEqual(try String(contentsOf: ancestor, encoding: .utf8), "preserve")
  }

  func testExistingSymbolicLinkIsRejectedWithoutChangingTarget() async throws {
    let directory = try makeDirectory()
    let target = directory.appendingPathComponent("target.json")
    let link = directory.appendingPathComponent("link.json")
    try Data("preserve".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    await assertThrowsAsyncError(
      try await WorkspaceExportFileWriter.write(Data("new".utf8), to: link))

    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "preserve")
  }

  func testDanglingSymbolicLinkIsRejected() async throws {
    let directory = try makeDirectory()
    let link = directory.appendingPathComponent("link.json")
    try FileManager.default.createSymbolicLink(
      at: link, withDestinationURL: directory.appendingPathComponent("missing.json"))

    await assertThrowsAsyncError(
      try await WorkspaceExportFileWriter.write(Data("new".utf8), to: link))

    XCTAssertNotNil(try FileManager.default.destinationOfSymbolicLink(atPath: link.path))
  }

  func testHardLinkedDestinationIsRejectedWithoutChangingEitherName() async throws {
    let directory = try makeDirectory()
    let original = directory.appendingPathComponent("original.json")
    let link = directory.appendingPathComponent("linked.json")
    try Data("preserve".utf8).write(to: original)
    try FileManager.default.linkItem(at: original, to: link)

    await assertThrowsAsyncError(
      try await WorkspaceExportFileWriter.write(Data("new".utf8), to: link))

    XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "preserve")
    XCTAssertEqual(try String(contentsOf: link, encoding: .utf8), "preserve")
  }

  func testDirectoryDestinationIsRejected() async throws {
    let directory = try makeDirectory()
    let destination = directory.appendingPathComponent("folder.json", isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)

    await assertThrowsAsyncError(
      try await WorkspaceExportFileWriter.write(Data(), to: destination))

    var isDirectory: ObjCBool = false
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory))
    XCTAssertTrue(isDirectory.boolValue)
  }

  func testNonFileURLIsRejected() async {
    await assertThrowsAsyncError(
      try await WorkspaceExportFileWriter.write(
        Data(), to: URL(string: "https://example.invalid/out.json")!))
  }

  func testNonJSONDestinationIsRejected() async throws {
    let destination = try makeDirectory().appendingPathComponent("workspace.txt")

    await assertThrowsAsyncError(
      try await WorkspaceExportFileWriter.write(Data(), to: destination))
  }

  func testWriterErrorDescriptionDoesNotExposeDestinationOrSecret() async throws {
    let secret = "writer-secret-sentinel"
    let destination = try makeDirectory().appendingPathComponent("\(secret).txt")

    do {
      try await WorkspaceExportFileWriter.write(Data(secret.utf8), to: destination)
      XCTFail("Expected invalid destination")
    } catch {
      let description = error.localizedDescription
      XCTAssertFalse(description.contains(secret))
      XCTAssertFalse(description.contains(destination.path))
    }
  }

  private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "WorkspaceExportFileWriterTests-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return directory
  }
}

private func assertThrowsAsyncError<T>(
  _ expression: @autoclosure () async throws -> T, file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await expression()
    XCTFail("Expected error", file: file, line: line)
  } catch {}
}
