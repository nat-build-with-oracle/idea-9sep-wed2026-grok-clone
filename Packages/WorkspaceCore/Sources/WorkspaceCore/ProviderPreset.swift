import Foundation

/// Setup suggestions, not a claim of account access or a different transport protocol.
public enum ProviderPreset: String, CaseIterable, Sendable, Identifiable {
  case custom, openAI, zai, nineRouter

  public var id: Self { self }
  public var name: String {
    switch self {
    case .custom: "Custom compatible endpoint"
    case .openAI: "OpenAI Platform"
    case .zai: "Z.ai general API"
    case .nineRouter: "9router local gateway"
    }
  }
  public var apiRoot: String {
    switch self {
    case .custom: "https://api.example.com/v1"
    case .openAI: "https://api.openai.com/v1"
    case .zai: "https://api.z.ai/api/paas/v4"
    case .nineRouter: "http://127.0.0.1:20128/v1"
    }
  }
  public var suggestedModel: String { self == .zai ? "glm-5.3" : "" }
  public var guidance: String {
    switch self {
    case .custom:
      "Use a documented OpenAI-compatible text chat endpoint and its own API key."
    case .openAI:
      "Requires an OpenAI Platform API key and API billing, not a ChatGPT subscription or auth.json token. Enter a model available to your account."
    case .zai:
      "Uses Z.ai general API billing and an API key. This standalone app does not use Coding Plan quota. The suggested model is editable and account access is not verified."
    case .nineRouter:
      "Start your own 9router separately. Enter its router API key, not an upstream provider key or OAuth token, and the exact model ID shown by your router. Explicitly enable loopback HTTP below. The gateway forwards chat to its configured upstream."
    }
  }
}
