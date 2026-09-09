import Darwin
import Foundation
import WorkspaceCore
import XCTest

@testable import NativeShell

final class AttachmentFileImporterTests: XCTestCase {
  func testReadsExactUnicodeBOMAndLineEndingBytesWithoutRetainingPath() throws {
    let fixture = try TemporaryAttachmentFiles()
    let data = Data([0xEF, 0xBB, 0xBF]) + Data("Hello 👩🏽‍💻\r\nsecond line\n".utf8)
    let url = try fixture.write(name: "notes.md", data: data)
    let conversationID = UUID()

    let contents = try AttachmentFileImporter.read(
      urls: [url], conversationID: conversationID)

    let content = try XCTUnwrap(contents.first)
    XCTAssertEqual(contents.count, 1)
    XCTAssertEqual(content.data, data)
    XCTAssertEqual(content.attachment.originalName, "notes.md")
    XCTAssertEqual(content.attachment.conversationID, conversationID)
    XCTAssertEqual(content.attachment.byteCount, data.count)
    XCTAssertFalse(String(describing: content).contains(fixture.directory.path))
  }

  func testManagedResultDoesNotChangeWhenOriginalChangesOrIsDeleted() throws {
    let fixture = try TemporaryAttachmentFiles()
    let original = Data("immutable copy".utf8)
    let url = try fixture.write(name: "copy.txt", data: original)

    let content = try XCTUnwrap(
      AttachmentFileImporter.read(urls: [url], conversationID: UUID()).first)
    try Data("changed source".utf8).write(to: url)
    try FileManager.default.removeItem(at: url)

    XCTAssertEqual(content.data, original)
    XCTAssertEqual(content.attachment.byteCount, original.count)
  }

  func testAcceptsDocumentedPlainTextTypesAndExtensionlessReadme() throws {
    let fixture = try TemporaryAttachmentFiles()
    let urls = try ["a.txt", "b.json", "c.csv", "d.log", "e.swift", "f.py", "README"].map {
      try fixture.write(name: $0, data: Data("safe text".utf8))
    }

    let contents = try AttachmentFileImporter.read(urls: urls, conversationID: UUID())

    XCTAssertEqual(contents.map(\.attachment.originalName), urls.map(\.lastPathComponent))
  }

  func testRejectsKnownBinaryTypeEvenWhenBytesAreASCII() throws {
    let fixture = try TemporaryAttachmentFiles()
    let url = try fixture.write(name: "fake.png", data: Data("plain ASCII".utf8))

    XCTAssertThrowsError(
      try AttachmentFileImporter.read(urls: [url], conversationID: UUID())
    ) { error in
      XCTAssertEqual(error as? AttachmentFileImportError, .unsupportedTextType)
    }
  }

  func testRejectsUnknownType() throws {
    let fixture = try TemporaryAttachmentFiles()
    let url = try fixture.write(name: "unknown.blobthing", data: Data("plain ASCII".utf8))

    XCTAssertThrowsError(
      try AttachmentFileImporter.read(urls: [url], conversationID: UUID())
    ) { error in
      XCTAssertEqual(error as? AttachmentFileImportError, .unsupportedTextType)
    }
  }

  func testRejectsInvalidUTF8NULAndOtherControls() throws {
    let fixture = try TemporaryAttachmentFiles()
    let samples: [(String, Data)] = [
      ("invalid.txt", Data([0xC3, 0x28])),
      ("nul.txt", Data([0x61, 0x00, 0x62])),
      ("control.txt", Data([0x61, 0x08, 0x62])),
    ]

    for (name, data) in samples {
      let url = try fixture.write(name: name, data: data)
      XCTAssertThrowsError(
        try AttachmentFileImporter.read(urls: [url], conversationID: UUID()), name
      ) { error in
        XCTAssertEqual(error as? AttachmentError, .invalidText, name)
      }
    }
  }

  func testAllowsTabCarriageReturnAndLineFeedControls() throws {
    let fixture = try TemporaryAttachmentFiles()
    let data = Data("one\ttwo\r\nthree\n".utf8)
    let url = try fixture.write(name: "controls.txt", data: data)

    let content = try XCTUnwrap(
      AttachmentFileImporter.read(urls: [url], conversationID: UUID()).first)

    XCTAssertEqual(content.data, data)
  }

  func testRejectsIndividualFileOverLimit() throws {
    let fixture = try TemporaryAttachmentFiles()
    let url = try fixture.write(
      name: "large.txt", data: Data(repeating: 0x61, count: AttachmentLimits.maxFileBytes + 1))

    XCTAssertThrowsError(
      try AttachmentFileImporter.read(urls: [url], conversationID: UUID())
    ) { error in
      XCTAssertEqual(error as? AttachmentError, .fileTooLarge)
    }
  }

  func testRejectsTooManyFilesBeforeReadingThem() {
    let urls = (0...AttachmentLimits.maxCount).map {
      URL(fileURLWithPath: "/not-read-\($0).txt")
    }

    XCTAssertThrowsError(
      try AttachmentFileImporter.read(urls: urls, conversationID: UUID())
    ) { error in
      XCTAssertEqual(error as? AttachmentError, .tooManyAttachments)
    }
  }

  func testRejectsBatchOverTotalLimit() throws {
    let fixture = try TemporaryAttachmentFiles()
    let bytes = 9 * 1_024 * 1_024
    let urls = try (0..<3).map {
      try fixture.write(name: "part-\($0).txt", data: Data(repeating: 0x61, count: bytes))
    }

    XCTAssertThrowsError(
      try AttachmentFileImporter.read(urls: urls, conversationID: UUID())
    ) { error in
      XCTAssertEqual(error as? AttachmentError, .draftTooLarge)
    }
  }

  func testRejectsDuplicateStandardizedURL() throws {
    let fixture = try TemporaryAttachmentFiles()
    let url = try fixture.write(name: "same.txt", data: Data("same".utf8))
    let equivalent = url.deletingLastPathComponent().appendingPathComponent("./same.txt")

    XCTAssertThrowsError(
      try AttachmentFileImporter.read(urls: [url, equivalent], conversationID: UUID())
    ) { error in
      XCTAssertEqual(error as? AttachmentFileImportError, .duplicateSelection)
    }
  }

  func testRejectsNonFileAndMissingURLsWithoutDisclosingPath() throws {
    let fixture = try TemporaryAttachmentFiles()
    let missing = fixture.directory.appendingPathComponent("private-name.txt")
    let remote = try XCTUnwrap(URL(string: "https://example.invalid/private-name.txt"))

    XCTAssertThrowsError(
      try AttachmentFileImporter.read(urls: [remote], conversationID: UUID())
    ) { error in
      XCTAssertEqual(error as? AttachmentFileImportError, .invalidSelection)
      XCTAssertFalse(error.localizedDescription.contains("private-name"))
    }
    XCTAssertThrowsError(
      try AttachmentFileImporter.read(urls: [missing], conversationID: UUID())
    ) { error in
      XCTAssertEqual(error as? AttachmentFileImportError, .unavailable)
      XCTAssertFalse(error.localizedDescription.contains("private-name"))
      XCTAssertFalse(error.localizedDescription.contains(fixture.directory.path))
    }
  }

  func testRejectsUnsafeFilename() throws {
    let fixture = try TemporaryAttachmentFiles()
    for name in ["unsafe\nname.txt", " leading.txt"] {
      let url = try fixture.write(name: name, data: Data("text".utf8))
      XCTAssertThrowsError(
        try AttachmentFileImporter.read(urls: [url], conversationID: UUID())
      ) { error in
        XCTAssertEqual(error as? AttachmentFileImportError, .invalidSelection)
      }
    }
  }

  func testRejectsDirectorySymlinkAndFIFOWitoutBlocking() throws {
    let fixture = try TemporaryAttachmentFiles()
    let directory = fixture.directory.appendingPathComponent("folder.txt", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let target = try fixture.write(name: "target.txt", data: Data("target".utf8))
    let symlink = fixture.directory.appendingPathComponent("link.txt")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
    let fifo = fixture.directory.appendingPathComponent("pipe.txt")
    let fifoResult = fifo.withUnsafeFileSystemRepresentation { path in
      guard let path else { return Int32(-1) }
      return Darwin.mkfifo(path, S_IRUSR | S_IWUSR)
    }
    XCTAssertEqual(fifoResult, 0)

    for url in [directory, symlink, fifo] {
      XCTAssertThrowsError(
        try AttachmentFileImporter.read(urls: [url], conversationID: UUID())
      ) { error in
        XCTAssertEqual(error as? AttachmentFileImportError, .notRegularFile)
      }
    }
  }

  func testEmptySelectionReturnsEmptyWithoutMeaningDraftClear() throws {
    XCTAssertEqual(
      try AttachmentFileImporter.read(urls: [], conversationID: UUID()), [])
  }

  @MainActor
  func testChooserCancelBeforeChooseReturnsNilWithoutPresentingPanel() async {
    let chooser = NativeAttachmentFileChooser()
    chooser.cancel()

    let result = await chooser.choose()

    XCTAssertNil(result)
  }
}

private final class TemporaryAttachmentFiles {
  let directory: URL

  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "AttachmentFileImporterTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
  }

  deinit {
    try? FileManager.default.removeItem(at: directory)
  }

  func write(name: String, data: Data) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try data.write(to: url, options: .atomic)
    return url
  }
}
