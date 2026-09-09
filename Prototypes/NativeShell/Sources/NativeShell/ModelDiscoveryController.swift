import Foundation
import SwiftUI
import WorkspaceCore

/// A lookup is scoped to the current form, never a persisted provider credential or chat request.
@MainActor final class ModelDiscoveryController: ObservableObject {
  @Published private(set) var models: [String] = []
  @Published private(set) var isLoading = false
  @Published private(set) var hasLoaded = false
  @Published private(set) var errorMessage: String?
  private let catalog: any RouterModelCatalog
  private var task: Task<Void, Never>?
  private var generation = 0

  init(catalog: any RouterModelCatalog = LocalRouterModelCatalog()) { self.catalog = catalog }
  deinit { task?.cancel() }

  func reset() {
    generation += 1
    task?.cancel()
    task = nil
    models = []
    isLoading = false
    hasLoaded = false
    errorMessage = nil
  }

  @discardableResult
  func discover(apiRoot: String, allowsLoopbackHTTP: Bool) -> Task<Void, Never>? {
    reset()
    guard let root = URL(string: apiRoot.trimmingCharacters(in: .whitespacesAndNewlines)),
      (try? LocalRouterModelCatalog.endpoint(apiRoot: root, allowsLoopbackHTTP: allowsLoopbackHTTP))
        != nil
    else {
      errorMessage = ModelCatalogError.localEndpointRequired.localizedDescription
      return nil
    }
    let requestedGeneration = generation
    isLoading = true
    task = Task { [weak self, catalog] in
      do {
        let models = try await catalog.models(apiRoot: root, allowsLoopbackHTTP: allowsLoopbackHTTP)
        guard !Task.isCancelled, let self, generation == requestedGeneration else { return }
        self.models = models
        hasLoaded = true
        isLoading = false
        task = nil
      } catch {
        guard !Task.isCancelled, let self, generation == requestedGeneration else { return }
        errorMessage =
          (error as? ModelCatalogError)?.localizedDescription
          ?? ProviderError.sanitized(error).localizedDescription
        isLoading = false
        task = nil
      }
    }
    return task
  }
}
