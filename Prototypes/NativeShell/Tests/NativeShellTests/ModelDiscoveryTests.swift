import Foundation
import XCTest

@testable import NativeShell
@testable import WorkspaceCore

@MainActor final class ModelDiscoveryTests: XCTestCase {
  func testDiscoveryIsIdleUntilExplicitlyRequested() {
    let controller = ModelDiscoveryController(catalog: ImmediateCatalog(models: ["glm/fixture"]))
    XCTAssertFalse(controller.isLoading)
    XCTAssertFalse(controller.hasLoaded)
    XCTAssertTrue(controller.models.isEmpty)
    XCTAssertNil(controller.errorMessage)
  }

  func testExplicitLookupPublishesQualifiedIDsAndLoadedState() async throws {
    let controller = ModelDiscoveryController(
      catalog: ImmediateCatalog(models: ["cx/fixture", "glm/fixture"]))
    let task = try XCTUnwrap(
      controller.discover(apiRoot: "http://127.0.0.1:20128/v1", allowsLoopbackHTTP: true))
    XCTAssertTrue(controller.isLoading)
    await task.value
    XCTAssertEqual(controller.models, ["cx/fixture", "glm/fixture"])
    XCTAssertFalse(controller.isLoading)
    XCTAssertTrue(controller.hasLoaded)
    XCTAssertNil(controller.errorMessage)
  }

  func testEmptyListIsLoadedRatherThanFabricatedModels() async throws {
    let controller = ModelDiscoveryController(catalog: ImmediateCatalog(models: []))
    let task = try XCTUnwrap(
      controller.discover(apiRoot: "http://localhost/v1", allowsLoopbackHTTP: true))
    await task.value
    XCTAssertTrue(controller.hasLoaded)
    XCTAssertTrue(controller.models.isEmpty)
  }

  func testRemoteOrUnapprovedHTTPDoesNotStartCatalogTask() {
    let catalog = SuspendedCatalog()
    let controller = ModelDiscoveryController(catalog: catalog)
    XCTAssertNil(
      controller.discover(apiRoot: "https://remote.invalid/v1", allowsLoopbackHTTP: true))
    XCTAssertEqual(
      controller.errorMessage, ModelCatalogError.localEndpointRequired.localizedDescription)
    XCTAssertNil(controller.discover(apiRoot: "http://localhost/v1", allowsLoopbackHTTP: false))
    XCTAssertFalse(controller.isLoading)
    XCTAssertFalse(controller.hasLoaded)
  }

  func testErrorIsSanitizedWithoutEchoingDetails() async throws {
    let controller = ModelDiscoveryController(catalog: FailedCatalog())
    let task = try XCTUnwrap(
      controller.discover(apiRoot: "https://localhost/v1", allowsLoopbackHTTP: false))
    await task.value
    XCTAssertEqual(controller.errorMessage, ProviderError.offline.localizedDescription)
    XCTAssertFalse(controller.hasLoaded)
    XCTAssertFalse(controller.isLoading)
  }

  func testResetRejectsLateResultsFromUncooperativeCatalog() async throws {
    let catalog = SuspendedCatalog()
    let controller = ModelDiscoveryController(catalog: catalog)
    var starts = catalog.starts.makeAsyncIterator()
    let request = try XCTUnwrap(
      controller.discover(apiRoot: "http://localhost/v1", allowsLoopbackHTTP: true))
    let started = await starts.next()
    XCTAssertEqual(started, 0)
    controller.reset()
    await catalog.resolve(0, models: ["old/model"])
    await request.value
    XCTAssertTrue(request.isCancelled)
    XCTAssertTrue(controller.models.isEmpty)
    XCTAssertFalse(controller.hasLoaded)
    XCTAssertFalse(controller.isLoading)
    XCTAssertNil(controller.errorMessage)
  }

  func testNewLookupWinsWhenOldRequestFinishesAfterIt() async throws {
    let catalog = SuspendedCatalog()
    let controller = ModelDiscoveryController(catalog: catalog)
    var starts = catalog.starts.makeAsyncIterator()
    let first = try XCTUnwrap(
      controller.discover(apiRoot: "http://localhost:20128/v1", allowsLoopbackHTTP: true))
    _ = await starts.next()
    let second = try XCTUnwrap(
      controller.discover(apiRoot: "http://localhost:20129/v1", allowsLoopbackHTTP: true))
    _ = await starts.next()
    await catalog.resolve(1, models: ["new/model"])
    await second.value
    await catalog.resolve(0, models: ["old/model"])
    await first.value
    XCTAssertEqual(controller.models, ["new/model"])
    XCTAssertTrue(controller.hasLoaded)
    XCTAssertNil(controller.errorMessage)
  }
}

private struct ImmediateCatalog: RouterModelCatalog {
  let models: [String]
  func models(apiRoot: URL, allowsLoopbackHTTP: Bool) async throws -> [String] { models }
}

private struct FailedCatalog: RouterModelCatalog {
  func models(apiRoot: URL, allowsLoopbackHTTP: Bool) async throws -> [String] {
    throw NSError(
      domain: "private-router-url-and-credential", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "private error must not reach the UI"])
  }
}

/// Deliberately ignores cancellation, proving that form generation guards reject late callbacks.
private actor SuspendedCatalog: RouterModelCatalog {
  nonisolated let starts: AsyncStream<Int>
  private let emitter: AsyncStream<Int>.Continuation
  private var requests: [Int: CheckedContinuation<[String], Error>] = [:]
  private var nextID = 0
  init() { (starts, emitter) = AsyncStream<Int>.makeStream() }
  func models(apiRoot: URL, allowsLoopbackHTTP: Bool) async throws -> [String] {
    let id = nextID
    nextID += 1
    return try await withCheckedThrowingContinuation { continuation in
      requests[id] = continuation
      emitter.yield(id)
    }
  }
  func resolve(_ id: Int, models: [String]) {
    requests.removeValue(forKey: id)?.resume(returning: models)
  }
}
