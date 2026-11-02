import Foundation

public struct GlobalResetEvent: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  /// A public confirmation/observation time, not a per-account reset receipt.
  public let confirmedAt: Date
  public let sourceURL: URL

  public init(id: String, confirmedAt: Date, sourceURL: URL) {
    self.id = id
    self.confirmedAt = confirmedAt
    self.sourceURL = sourceURL
  }

  public func dateKey(timeZone: TimeZone = .current) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: confirmedAt)
  }
}

public struct GlobalResetForecast: Codable, Equatable, Sendable {
  public let updatedAt: Date
  public let percent24h: Double
  public let percent48h: Double
  public let confidence: String

  public init(updatedAt: Date, percent24h: Double, percent48h: Double, confidence: String) {
    self.updatedAt = updatedAt
    self.percent24h = percent24h
    self.percent48h = percent48h
    self.confidence = confidence
  }

  public func isFresh(at now: Date = Date()) -> Bool {
    let age = now.timeIntervalSince(updatedAt)
    return age >= -300 && age <= 1_800
  }
}

public struct ResetRadarSnapshot: Codable, Equatable, Sendable {
  public let events: [GlobalResetEvent]
  public let forecast: GlobalResetForecast
  public let historyUpdatedAt: Date
  public let fetchedAt: Date

  public init(
    events: [GlobalResetEvent], forecast: GlobalResetForecast,
    historyUpdatedAt: Date, fetchedAt: Date
  ) {
    self.events = events
    self.forecast = forecast
    self.historyUpdatedAt = historyUpdatedAt
    self.fetchedAt = fetchedAt
  }
}

public enum ResetRadarError: Error, LocalizedError, Sendable {
  case invalidResponse
  case unavailable
  case rateLimited

  public var errorDescription: String? {
    switch self {
    case .invalidResponse: return "Reset source data could not be verified."
    case .unavailable: return "Reset source is temporarily unavailable."
    case .rateLimited: return "Reset source requested a pause before retrying."
    }
  }
}

public enum ResetRadarParser {
  public static func parseForecast(_ data: Data, now: Date = Date()) throws -> GlobalResetForecast {
    struct Payload: Decodable {
      struct Probabilities: Decodable {
        let rounded24H: Double
        let rounded48H: Double
      }
      let updatedAt: String
      let probabilities: Probabilities
      let confidence: String
    }
    let payload = try decoder().decode(Payload.self, from: data)
    guard let updatedAt = timestamp(payload.updatedAt),
      updatedAt.timeIntervalSince(now) <= 300,
      (0...100).contains(payload.probabilities.rounded24H),
      (0...100).contains(payload.probabilities.rounded48H),
      payload.probabilities.rounded48H >= payload.probabilities.rounded24H
    else { throw ResetRadarError.invalidResponse }
    return GlobalResetForecast(
      updatedAt: updatedAt,
      percent24h: payload.probabilities.rounded24H,
      percent48h: payload.probabilities.rounded48H,
      confidence: payload.confidence.lowercased()
    )
  }

  public static func parseTimeline(
    _ data: Data, now: Date = Date()
  ) throws -> (events: [GlobalResetEvent], updatedAt: Date) {
    struct Payload: Decodable {
      struct Event: Decodable {
        let id: String
        let type: String
        let group: String
        let scope: String?
        let confirmed: Bool?
        let preview: Bool?
        let bankedGrant: Bool?
        let resetKind: String?
        let announcementState: String?
        let announcedAt: String?
        let url: String?
      }
      let updatedAt: String
      let events: [Event]
    }
    let payload = try decoder().decode(Payload.self, from: data)
    guard let updatedAt = timestamp(payload.updatedAt),
      updatedAt.timeIntervalSince(now) <= 300
    else { throw ResetRadarError.invalidResponse }

    var seen = Set<String>()
    let events = payload.events.compactMap { record -> GlobalResetEvent? in
      // Completion evidence is required in addition to the documented group.
      // Unknown confirmations, previews and banked grants never become RESET.
      guard record.type == "reset", record.group == "reset",
        record.scope == "global", record.confirmed == true,
        record.announcementState == "announced",
        record.preview != true, record.bankedGrant != true,
        record.resetKind != "banked",
        let rawTime = record.announcedAt, let date = timestamp(rawTime),
        date <= now, let rawURL = record.url,
        let url = officialPostURL(rawURL, id: record.id),
        seen.insert(record.id).inserted
      else { return nil }
      return GlobalResetEvent(id: record.id, confirmedAt: date, sourceURL: url)
    }
    return (Array(events.sorted { $0.confirmedAt > $1.confirmedAt }.prefix(128)), updatedAt)
  }

  private static func officialPostURL(_ raw: String, id: String) -> URL? {
    guard !id.isEmpty, id.allSatisfy({ $0.isASCII && $0.isNumber }),
      let url = URL(string: raw), url.scheme == "https",
      ["x.com", "www.x.com", "twitter.com", "www.twitter.com"].contains(url.host?.lowercased() ?? ""),
      url.user == nil, url.password == nil, url.port == nil,
      url.query == nil, url.fragment == nil,
      url.path == "/thsottiaux/status/\(id)"
    else { return nil }
    return URL(string: "https://x.com/thsottiaux/status/\(id)")
  }

  private static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
  }

  private static func timestamp(_ raw: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: raw) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: raw)
  }
}

public actor ResetRadarClient {
  public static let sourceURL = URL(string: "https://codex-reset.com/")!
  private let session: URLSession
  private var retryAfter: Date?
  private var lastAttempt: Date?
  private var cached: ResetRadarSnapshot?

  public init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 12
    configuration.timeoutIntervalForResource = 15
    configuration.httpCookieStorage = nil
    session = URLSession(configuration: configuration)
  }

  public func fetch() async throws -> ResetRadarSnapshot {
    guard retryAfter.map({ $0 <= Date() }) ?? true else {
      throw ResetRadarError.rateLimited
    }
    if let cached, Date().timeIntervalSince(cached.fetchedAt) < 60 { return cached }
    if let lastAttempt, Date().timeIntervalSince(lastAttempt) < 60 {
      throw ResetRadarError.rateLimited
    }
    lastAttempt = Date()
    async let forecastData = request("api/forecast")
    async let timelineData = request("api/timeline")
    let (forecastBytes, timelineBytes) = try await (forecastData, timelineData)
    let now = Date()
    let forecast = try ResetRadarParser.parseForecast(forecastBytes, now: now)
    let timeline = try ResetRadarParser.parseTimeline(timelineBytes, now: now)
    let snapshot = ResetRadarSnapshot(
      events: timeline.events, forecast: forecast,
      historyUpdatedAt: timeline.updatedAt, fetchedAt: now
    )
    cached = snapshot
    return snapshot
  }

  private func request(_ path: String) async throws -> Data {
    var request = URLRequest(url: Self.sourceURL.appendingPathComponent(path))
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(
      "CodexMonitor/1.4.6 (+https://github.com/Mintzz666/codex-monitor)",
      forHTTPHeaderField: "User-Agent"
    )
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse,
      response.url?.host == Self.sourceURL.host
    else { throw ResetRadarError.invalidResponse }
    if response.statusCode == 429 {
      let raw = response.value(forHTTPHeaderField: "Retry-After") ?? ""
      let seconds = Double(raw)
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
      let requestedPause = seconds?.isFinite == true
        ? seconds! : formatter.date(from: raw)?.timeIntervalSinceNow ?? 300
      retryAfter = Date().addingTimeInterval(max(300, requestedPause))
      throw ResetRadarError.rateLimited
    }
    guard response.statusCode == 200 else { throw ResetRadarError.unavailable }
    guard response.mimeType?.lowercased() == "application/json", data.count <= 1_000_000 else {
      throw ResetRadarError.invalidResponse
    }
    return data
  }
}
