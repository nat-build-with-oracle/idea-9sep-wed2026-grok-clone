import Foundation
import WorkspaceCore

@MainActor
final class SmokeAttachmentChooser: AttachmentFileChoosing {
  private let urls: [URL]
  private(set) var chooseCount = 0
  private(set) var cancelCount = 0

  init(urls: [URL]) { self.urls = urls }

  func choose() async -> [URL]? {
    chooseCount += 1
    return urls
  }

  func cancel() { cancelCount += 1 }
}

actor SmokeAttachmentCredentials: CredentialStore {
  private let reference: String
  private let value: Data
  private var reads = 0

  init(reference: String, value: Data) {
    self.reference = reference
    self.value = value
  }

  func read(_ reference: String) throws -> Data {
    guard reference == self.reference else { throw ProviderError.missingCredential }
    reads += 1
    return value
  }

  func write(_ secret: Data, for reference: String) throws {}
  func remove(_ reference: String) throws {}
  func readCount() -> Int { reads }
}

final class SmokeAttachmentProvider: ChatProvider, @unchecked Sendable {
  private let lock = NSLock()
  private var requests: [ChatRequest] = []

  var callCount: Int { lock.withLock { requests.count } }
  var lastRequest: ChatRequest? { lock.withLock { requests.last } }

  func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
    lock.withLock { requests.append(request) }
    return AsyncThrowingStream { continuation in
      continuation.yield(.text("Offline attachment received."))
      continuation.yield(.finished)
      continuation.finish()
    }
  }
}

struct AttachmentSmokeFailure: LocalizedError {
  let stage: String
  var errorDescription: String? { "Offline attachment smoke failed at \(stage)." }
}
