import Foundation

public struct SharedUsageWindow: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let label: String?
  public let usedPercent: Double
  public let windowDurationMinutes: Int
  public let resetsAt: Date?

  public init(
    id: String,
    label: String?,
    usedPercent: Double,
    windowDurationMinutes: Int,
    resetsAt: Date?
  ) {
    self.id = id
    self.label = label
    self.usedPercent = min(100, max(0, usedPercent))
    self.windowDurationMinutes = windowDurationMinutes
    self.resetsAt = resetsAt
  }

  public var remainingPercent: Double { max(0, 100 - usedPercent) }
}

public struct SharedDailyTokenUsage: Codable, Equatable, Sendable, Identifiable {
  public let startDate: String
  public let tokens: Int64

  public init(startDate: String, tokens: Int64) {
    self.startDate = startDate
    self.tokens = max(0, tokens)
  }

  public var id: String { startDate }
}

public struct SharedUsageSnapshot: Codable, Equatable, Sendable {
  public let usedPercent: Double
  public let resetsAt: Date?
  public let planType: String?
  public let limitName: String?
  public let updatedAt: Date
  public let windowDurationMinutes: Int?
  public let languageCode: String?
  public let subscriptionID: String?
  public let additionalWindows: [SharedUsageWindow]?
  public let dailyTokenUsage: [SharedDailyTokenUsage]?
  public let lifetimeTokens: Int64?

  public init(
    usedPercent: Double,
    resetsAt: Date?,
    planType: String?,
    limitName: String?,
    updatedAt: Date,
    windowDurationMinutes: Int? = nil,
    languageCode: String? = nil,
    subscriptionID: String? = nil,
    additionalWindows: [SharedUsageWindow]? = nil,
    dailyTokenUsage: [SharedDailyTokenUsage]? = nil,
    lifetimeTokens: Int64? = nil
  ) {
    self.usedPercent = min(100, max(0, usedPercent))
    self.resetsAt = resetsAt
    self.planType = planType
    self.limitName = limitName
    self.updatedAt = updatedAt
    self.windowDurationMinutes = windowDurationMinutes
    self.languageCode = languageCode
    self.subscriptionID = subscriptionID
    self.additionalWindows = additionalWindows
    self.dailyTokenUsage = dailyTokenUsage
    self.lifetimeTokens = lifetimeTokens
  }

  public var remainingPercent: Double {
    max(0, 100 - usedPercent)
  }

  public func isStale(
    relativeTo date: Date = Date(),
    maxAge: TimeInterval = 15 * 60
  ) -> Bool {
    date.timeIntervalSince(updatedAt) > maxAge
  }
}

public enum SharedUsageConfiguration {
  public static let widgetKind = "com.example.codexmonitor.usage-widget"
  public static let fallbackAppGroupIdentifier =
    "group.com.example.codexmonitor"

  public static func appGroupIdentifier(
    bundle: Bundle = .main
  ) -> String {
    guard
      let value = bundle.object(
        forInfoDictionaryKey: "CodexUsageAppGroupIdentifier"
      ) as? String,
      !value.isEmpty,
      !value.contains("$(")
    else {
      return fallbackAppGroupIdentifier
    }
    return value
  }
}
