import Foundation

enum RoutineFailureMapping {
  static func failure(_ error: Error) -> RoutineRun.Failure {
    if let workspace = error as? WorkspaceError {
      switch workspace {
      case .invalidProvider: return .providerChanged
      case .invalidRoutine: return .invalidSchedule
      default: return .storageUnavailable
      }
    }
    switch ProviderError.sanitized(error) {
    case .attachmentTransmissionUnavailable: return .attachmentTransmissionUnavailable
    case .missingCredential, .keychain: return .missingCredential
    case .invalidCredential, .http(401), .http(403): return .invalidCredential
    case .codexLoginRequired, .invalidCodexLogin: return .loginRequired
    case .http(429): return .rateLimited
    case .unsupportedContent: return .unsupportedContent
    case .outputLimit: return .outputLimit
    case .storageFailure: return .storageUnavailable
    case .cancelled: return .cancelled
    case .invalidResponse, .streamEnded: return .invalidResponse
    default: return .unavailable
    }
  }
}
