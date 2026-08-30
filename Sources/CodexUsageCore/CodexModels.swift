import Foundation

struct RPCEnvelope<Result: Decodable & Sendable>: Decodable, Sendable {
  let id: Int?
  let result: Result?
  let error: RPCErrorPayload?
}

struct RPCErrorPayload: Decodable, Sendable, LocalizedError {
  let code: Int
  let message: String

  var errorDescription: String? {
    "Codex app-server 错误 \(code)：\(message)"
  }
}

struct AccountReadResult: Decodable, Sendable {
  let account: CodexAccount?
  let requiresOpenaiAuth: Bool?
}

struct CodexAccount: Decodable, Sendable {
  let type: String?
  let planType: String?
}

public struct RateLimitsReadResult: Decodable, Sendable {
  let rateLimits: CodexRateLimitSnapshot?
  let rateLimitsByLimitId: [String: CodexRateLimitSnapshot]?
}

struct AccountUsageReadResult: Decodable, Sendable {
  let summary: AccountUsageSummary?
  let dailyUsageBuckets: [AccountDailyUsageBucket]?
}

struct AccountUsageSummary: Decodable, Sendable {
  let lifetimeTokens: Int64?
  let peakDailyTokens: Int64?
  let longestRunningTurnSec: Int64?
  let currentStreakDays: Int?
  let longestStreakDays: Int?
}

struct AccountDailyUsageBucket: Decodable, Sendable {
  let startDate: String
  let tokens: Int64
}

struct CodexRateLimitSnapshot: Decodable, Sendable {
  let limitId: String?
  let limitName: String?
  let planType: String?
  let primary: CodexRateLimitWindow?
  let secondary: CodexRateLimitWindow?
  let rateLimitReachedType: String?
}

struct CodexRateLimitWindow: Decodable, Sendable {
  let usedPercent: Double?
  let windowDurationMins: Int?
  let resetsAt: Int64?

  private enum CodingKeys: String, CodingKey {
    case usedPercent
    case windowDurationMins
    case windowDurationSeconds
    case resetsAt
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    usedPercent = try container.decodeFlexibleDouble(forKey: .usedPercent)

    if let minutes = try container.decodeFlexibleInt(
      forKey: .windowDurationMins
    ) {
      windowDurationMins = minutes
    } else if let seconds = try container.decodeFlexibleInt(
      forKey: .windowDurationSeconds
    ) {
      windowDurationMins = max(1, (seconds + 59) / 60)
    } else {
      windowDurationMins = nil
    }

    resetsAt = try container.decodeFlexibleInt64(forKey: .resetsAt)
  }
}

extension KeyedDecodingContainer {
  fileprivate func decodeFlexibleDouble(forKey key: Key) throws -> Double? {
    do {
      return try decodeIfPresent(Double.self, forKey: key)
    } catch {
      let value = try decodeIfPresent(String.self, forKey: key)
      return value.flatMap(Double.init)
    }
  }

  fileprivate func decodeFlexibleInt(forKey key: Key) throws -> Int? {
    do {
      return try decodeIfPresent(Int.self, forKey: key)
    } catch {
      if let value = try decodeIfPresent(String.self, forKey: key),
        let parsed = Int(value)
      {
        return parsed
      }
      if let value = try decodeIfPresent(Double.self, forKey: key),
        value.isFinite,
        value.rounded() == value
      {
        return Int(value)
      }
      return nil
    }
  }

  fileprivate func decodeFlexibleInt64(forKey key: Key) throws -> Int64? {
    do {
      return try decodeIfPresent(Int64.self, forKey: key)
    } catch {
      if let value = try decodeIfPresent(String.self, forKey: key) {
        if let parsed = Int64(value) {
          return parsed
        }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) {
          return Int64(date.timeIntervalSince1970)
        }
      }
      if let value = try decodeIfPresent(Double.self, forKey: key),
        value.isFinite,
        value.rounded() == value
      {
        return Int64(value)
      }
      return nil
    }
  }
}

public struct UsageWindow: Sendable, Equatable, Identifiable {
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

public struct DailyTokenUsage: Sendable, Equatable, Identifiable {
  public let startDate: String
  public let tokens: Int64

  public init(startDate: String, tokens: Int64) {
    self.startDate = startDate
    self.tokens = max(0, tokens)
  }

  public var id: String { startDate }
}

public enum DailyTokenSeries {
  public static func sevenDaysEnding(
    on date: Date,
    buckets: [DailyTokenUsage],
    timeZone: TimeZone = .current
  ) -> [DailyTokenUsage] {
    var valuesByDate: [String: Int64] = [:]
    for bucket in buckets {
      valuesByDate[bucket.startDate, default: 0] += bucket.tokens
    }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone

    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd"

    return (-6...0).compactMap { offset in
      guard let day = calendar.date(byAdding: .day, value: offset, to: date)
      else { return nil }
      let key = formatter.string(from: day)
      return DailyTokenUsage(startDate: key, tokens: valuesByDate[key] ?? 0)
    }
  }
}

public struct TokenUsage: Sendable, Equatable {
  public let lifetimeTokens: Int64?
  public let peakDailyTokens: Int64?
  public let currentStreakDays: Int?
  public let dailyBuckets: [DailyTokenUsage]

  public init(
    lifetimeTokens: Int64?,
    peakDailyTokens: Int64?,
    currentStreakDays: Int?,
    dailyBuckets: [DailyTokenUsage]
  ) {
    self.lifetimeTokens = lifetimeTokens
    self.peakDailyTokens = peakDailyTokens
    self.currentStreakDays = currentStreakDays
    self.dailyBuckets = dailyBuckets
  }
}

public struct UsageSnapshot: Sendable, Equatable {
  public let usedPercent: Double
  public let windowDurationMinutes: Int
  public let resetsAt: Date?
  public let planType: String?
  public let limitName: String?
  public let reachedLimitType: String?
  public let additionalWindows: [UsageWindow]
  public let tokenUsage: TokenUsage?

  public init(
    usedPercent: Double,
    windowDurationMinutes: Int,
    resetsAt: Date?,
    planType: String?,
    limitName: String?,
    reachedLimitType: String?,
    additionalWindows: [UsageWindow] = [],
    tokenUsage: TokenUsage? = nil
  ) {
    self.usedPercent = usedPercent
    self.windowDurationMinutes = windowDurationMinutes
    self.resetsAt = resetsAt
    self.planType = planType
    self.limitName = limitName
    self.reachedLimitType = reachedLimitType
    self.additionalWindows = additionalWindows
    self.tokenUsage = tokenUsage
  }

  public var remainingPercent: Double {
    max(0, 100 - usedPercent)
  }

  public func attaching(tokenUsage: TokenUsage?) -> UsageSnapshot {
    UsageSnapshot(
      usedPercent: usedPercent,
      windowDurationMinutes: windowDurationMinutes,
      resetsAt: resetsAt,
      planType: planType,
      limitName: limitName,
      reachedLimitType: reachedLimitType,
      additionalWindows: additionalWindows,
      tokenUsage: tokenUsage
    )
  }
}

public enum UsageSelectionError: LocalizedError, Equatable {
  case noRateLimits
  case noWeeklyWindow
  case missingUsagePercent

  public var errorDescription: String? {
    switch self {
    case .noRateLimits:
      return "Codex 没有返回限额数据"
    case .noWeeklyWindow:
      return "Codex 返回了限额数据，但没有找到周限额窗口"
    case .missingUsagePercent:
      return "周限额数据缺少使用百分比"
    }
  }
}

public enum WeeklyUsageSelector {
  private static let weeklyWindowMinutes = 7 * 24 * 60
  private static let acceptedWindowRange = (6 * 24 * 60)...(8 * 24 * 60)

  private struct Candidate {
    let snapshot: CodexRateLimitSnapshot
    let window: CodexRateLimitWindow
    let sourceName: String?
    let sourcePriority: Int
  }

  public static func select(
    from result: RateLimitsReadResult,
    accountPlanType: String?
  ) throws -> UsageSnapshot {
    var candidates: [Candidate] = []

    if let defaultSnapshot = result.rateLimits {
      appendWindows(
        from: defaultSnapshot,
        sourceName: defaultSnapshot.limitName ?? defaultSnapshot.limitId,
        sourcePriority: 0,
        to: &candidates
      )
    }

    for (key, snapshot) in (result.rateLimitsByLimitId ?? [:]).sorted(by: { $0.key < $1.key }) {
      let priority = key == "codex" ? 1 : 2
      appendWindows(
        from: snapshot,
        sourceName: snapshot.limitName ?? snapshot.limitId ?? key,
        sourcePriority: priority,
        to: &candidates
      )
    }

    guard !candidates.isEmpty else {
      throw UsageSelectionError.noRateLimits
    }

    let weeklyCandidates = candidates.filter {
      guard let duration = $0.window.windowDurationMins else {
        return false
      }
      return acceptedWindowRange.contains(duration)
    }

    guard let selected = weeklyCandidates.min(by: candidateSort) else {
      throw UsageSelectionError.noWeeklyWindow
    }
    guard let rawUsedPercent = selected.window.usedPercent else {
      throw UsageSelectionError.missingUsagePercent
    }

    let duration = selected.window.windowDurationMins ?? weeklyWindowMinutes
    let resetsAt = selected.window.resetsAt.map {
      Date(timeIntervalSince1970: TimeInterval($0))
    }

    return UsageSnapshot(
      usedPercent: min(100, max(0, rawUsedPercent)),
      windowDurationMinutes: duration,
      resetsAt: resetsAt,
      planType: accountPlanType ?? selected.snapshot.planType,
      limitName: selected.sourceName,
      reachedLimitType: selected.snapshot.rateLimitReachedType,
      additionalWindows: selectAdditionalWindows(
        from: candidates,
        matchingLimitID: selected.snapshot.limitId
      )
    )
  }

  private static func selectAdditionalWindows(
    from candidates: [Candidate],
    matchingLimitID: String?
  ) -> [UsageWindow] {
    var seen = Set<String>()
    return candidates.compactMap { candidate in
      guard
        candidate.snapshot.limitId == matchingLimitID,
        let duration = candidate.window.windowDurationMins,
        !acceptedWindowRange.contains(duration),
        let usedPercent = candidate.window.usedPercent
      else {
        return nil
      }

      let reset = candidate.window.resetsAt ?? 0
      let key = "\(duration)-\(usedPercent)-\(reset)"
      guard seen.insert(key).inserted else { return nil }

      return UsageWindow(
        id: "\(candidate.sourceName ?? "window")-\(duration)-\(reset)",
        label: candidate.sourceName,
        usedPercent: usedPercent,
        windowDurationMinutes: duration,
        resetsAt: candidate.window.resetsAt.map {
          Date(timeIntervalSince1970: TimeInterval($0))
        }
      )
    }
    .sorted { $0.windowDurationMinutes < $1.windowDurationMinutes }
  }

  private static func appendWindows(
    from snapshot: CodexRateLimitSnapshot,
    sourceName: String?,
    sourcePriority: Int,
    to candidates: inout [Candidate]
  ) {
    if let primary = snapshot.primary {
      candidates.append(
        Candidate(
          snapshot: snapshot,
          window: primary,
          sourceName: sourceName,
          sourcePriority: sourcePriority
        )
      )
    }
    if let secondary = snapshot.secondary {
      candidates.append(
        Candidate(
          snapshot: snapshot,
          window: secondary,
          sourceName: sourceName,
          sourcePriority: sourcePriority
        )
      )
    }
  }

  private static func candidateSort(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
    let leftDistance = abs((lhs.window.windowDurationMins ?? 0) - weeklyWindowMinutes)
    let rightDistance = abs((rhs.window.windowDurationMins ?? 0) - weeklyWindowMinutes)
    if leftDistance != rightDistance {
      return leftDistance < rightDistance
    }
    return lhs.sourcePriority < rhs.sourcePriority
  }
}
