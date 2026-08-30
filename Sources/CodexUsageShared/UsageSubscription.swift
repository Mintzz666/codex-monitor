import Foundation

public enum UsageSubscription: String, CaseIterable, Codable, Identifiable, Sendable {
  case codex

  public var id: String {
    rawValue
  }

  public var displayName: String {
    "Codex"
  }

  public var usesWeeklyWindow: Bool {
    true
  }

  public static func resolve(_ storedValue: String?) -> UsageSubscription {
    guard let storedValue, let subscription = UsageSubscription(rawValue: storedValue) else {
      return .codex
    }
    return subscription
  }
}
