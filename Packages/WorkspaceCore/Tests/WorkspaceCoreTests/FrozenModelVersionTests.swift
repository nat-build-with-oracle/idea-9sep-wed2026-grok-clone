import CoreData
import CryptoKit
import XCTest

@testable import WorkspaceCore

final class FrozenModelVersionTests: XCTestCase {
  func testFrozenModelEntityVersionHashesMatchPreV4Head() {
    let models = [
      CoreDataWorkspaceRepository.modelV1(),
      CoreDataWorkspaceRepository.modelV2(),
      CoreDataWorkspaceRepository.modelV3(),
    ]
    // Golden values were captured from pre-V4 HEAD ad6f71b using Core Data's own entity hashes.
    XCTAssertEqual(
      models.map(combinedEntityHash),
      [
        "cec14a89f6f28ff7b40ac0dba08874b998754114b692b56c2b37f2fe87471073",
        "1ee43661c1f8d97ba8c408e8b93264cb1f958f330e1935365a24f15e403c120f",
        "2cb33d2ea883e946038f2ae3d288a0a554588fa46732da1c44ac7cbb23a2b8ad",
      ])
    XCTAssertEqual(
      models.map(\.versionIdentifiers),
      [["WorkspaceCore.v1"], ["WorkspaceCore.v2"], ["WorkspaceCore.v3"]])
  }

  private func combinedEntityHash(_ model: NSManagedObjectModel) -> String {
    let hashes = model.entityVersionHashesByName.mapValues { data in
      data.map { String(format: "%02x", $0) }.joined()
    }
    let canonical = hashes.keys.sorted().map { "\($0)=\(hashes[$0]!)" }.joined(separator: "\n")
    return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
