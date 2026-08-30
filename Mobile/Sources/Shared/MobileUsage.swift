import Foundation
import Security

struct MobileUsageSnapshot: Codable, Equatable, Sendable {
  let usedPercent: Double
  let resetsAt: Date
  let updatedAt: Date

  init(usedPercent: Double, resetsAt: Date, updatedAt: Date) {
    self.usedPercent = min(100, max(0, usedPercent))
    self.resetsAt = resetsAt
    self.updatedAt = updatedAt
  }

  var remainingPercent: Double { max(0, 100 - usedPercent) }

  static func preview(now: Date = Date()) -> Self {
    Self(
      usedPercent: 10,
      resetsAt: Calendar.current.date(byAdding: .day, value: 3, to: now) ?? now,
      updatedAt: now
    )
  }
}

protocol MobileUsageProviding: Sendable {
  func loadUsage() async throws -> MobileUsageSnapshot
}

enum MobileUsageProviderError: LocalizedError {
  case noStoredSnapshot
  case notSignedIn
  case invalidServerResponse
  case authorizationExpired
  case requestFailed(Int)
  case keychain(OSStatus)

  var errorDescription: String? {
    switch self {
    case .noStoredSnapshot: return "尚未收到额度数据"
    case .notSignedIn: return "请先登录 Codex 账号"
    case .invalidServerResponse: return "OpenAI 返回了无法识别的数据"
    case .authorizationExpired: return "登录授权已过期，请重新登录"
    case .requestFailed(let status): return "网络请求失败（\(status)）"
    case .keychain(let status): return "无法访问安全钥匙串（\(status)）"
    }
  }
}

struct PreviewMobileUsageProvider: MobileUsageProviding {
  func loadUsage() async throws -> MobileUsageSnapshot { .preview() }
}

struct DeviceAuthorization: Sendable {
  let verificationURL: URL
  let userCode: String
  fileprivate let deviceAuthID: String
  fileprivate let interval: TimeInterval
}

private struct CodexCredentials: Codable, Sendable {
  let idToken: String
  let accessToken: String
  let refreshToken: String
  let accountID: String?
}

private struct SharedKeychain: Sendable {
  private let service = "com.example.codexmonitor.mobile.auth"
  private let account = "codex-chatgpt-oauth"

  private var accessGroup: String? {
    Bundle.main.object(forInfoDictionaryKey: "CodexMonitorKeychainGroup") as? String
  }

  func load() throws -> CodexCredentials? {
    var query = baseQuery
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    query[kSecReturnData as String] = true
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw MobileUsageProviderError.keychain(status)
    }
    return try JSONDecoder().decode(CodexCredentials.self, from: data)
  }

  func save(_ credentials: CodexCredentials) throws {
    let data = try JSONEncoder().encode(credentials)
    let attributes = [kSecValueData as String: data]
    let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
    if updateStatus == errSecSuccess { return }
    guard updateStatus == errSecItemNotFound else {
      throw MobileUsageProviderError.keychain(updateStatus)
    }
    var query = baseQuery
    query[kSecValueData as String] = data
    query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let addStatus = SecItemAdd(query as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw MobileUsageProviderError.keychain(addStatus)
    }
  }

  func delete() throws {
    let status = SecItemDelete(baseQuery as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw MobileUsageProviderError.keychain(status)
    }
  }

  private var baseQuery: [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
    ]
    if let accessGroup, !accessGroup.isEmpty {
      query[kSecAttrAccessGroup as String] = accessGroup
    }
    return query
  }
}

actor CodexAccountService {
  static let shared = CodexAccountService()

  private let session: URLSession
  private let keychain = SharedKeychain()
  private let snapshotStore = MobileUsageSnapshotStore()
  private let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
  private let authBaseURL = URL(string: "https://auth.openai.com")!
  private let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

  init(session: URLSession = .shared) { self.session = session }

  func isSignedIn() -> Bool { (try? keychain.load()) != nil }

  func beginDeviceAuthorization() async throws -> DeviceAuthorization {
    struct Request: Encodable {
      let clientID: String
      enum CodingKeys: String, CodingKey { case clientID = "client_id" }
    }
    struct Response: Decodable {
      let deviceAuthID: String
      let userCode: String?
      let usercode: String?
      let interval: String
      enum CodingKeys: String, CodingKey {
        case deviceAuthID = "device_auth_id"
        case userCode = "user_code"
        case usercode
        case interval
      }
    }
    let url = authBaseURL.appending(path: "api/accounts/deviceauth/usercode")
    let response: Response = try await sendJSON(
      url: url,
      body: Request(clientID: clientID)
    )
    guard let code = response.userCode ?? response.usercode,
      let interval = TimeInterval(response.interval)
    else {
      throw MobileUsageProviderError.invalidServerResponse
    }
    return DeviceAuthorization(
      verificationURL: authBaseURL.appending(path: "codex/device"),
      userCode: code,
      deviceAuthID: response.deviceAuthID,
      interval: max(1, interval)
    )
  }

  func finishDeviceAuthorization(_ authorization: DeviceAuthorization) async throws
    -> MobileUsageSnapshot
  {
    struct PollRequest: Encodable {
      let deviceAuthID: String
      let userCode: String
      enum CodingKeys: String, CodingKey {
        case deviceAuthID = "device_auth_id"
        case userCode = "user_code"
      }
    }
    struct PollResponse: Decodable {
      let authorizationCode: String
      let codeVerifier: String
      enum CodingKeys: String, CodingKey {
        case authorizationCode = "authorization_code"
        case codeVerifier = "code_verifier"
      }
    }
    let pollURL = authBaseURL.appending(path: "api/accounts/deviceauth/token")
    let deadline = Date().addingTimeInterval(15 * 60)
    var pollResponse: PollResponse?
    while Date() < deadline {
      do {
        pollResponse = try await sendJSON(
          url: pollURL,
          body: PollRequest(
            deviceAuthID: authorization.deviceAuthID,
            userCode: authorization.userCode
          ),
          pendingStatuses: [403, 404]
        )
      } catch {
        guard isTransient(error) else { throw error }
      }
      if pollResponse != nil { break }
      try await Task.sleep(for: .seconds(authorization.interval))
    }
    guard let pollResponse else {
      throw MobileUsageProviderError.authorizationExpired
    }
    let credentials = try await exchangeAuthorizationCode(
      pollResponse.authorizationCode,
      codeVerifier: pollResponse.codeVerifier
    )
    try keychain.save(credentials)
    return try await loadUsage()
  }

  func loadUsage() async throws -> MobileUsageSnapshot {
    guard var credentials = try keychain.load() else {
      throw MobileUsageProviderError.notSignedIn
    }
    if tokenExpiresSoon(credentials.accessToken) {
      credentials = try await refresh(credentials)
    }
    do {
      return try await fetchUsageWithRetry(credentials)
    } catch MobileUsageProviderError.requestFailed(401) {
      credentials = try await refresh(credentials)
      return try await fetchUsageWithRetry(credentials)
    }
  }

  func signOut() throws { try keychain.delete() }

  private func exchangeAuthorizationCode(_ code: String, codeVerifier: String) async throws
    -> CodexCredentials
  {
    let items = [
      URLQueryItem(name: "grant_type", value: "authorization_code"),
      URLQueryItem(name: "code", value: code),
      URLQueryItem(name: "redirect_uri", value: "https://auth.openai.com/deviceauth/callback"),
      URLQueryItem(name: "client_id", value: clientID),
      URLQueryItem(name: "code_verifier", value: codeVerifier),
    ]
    let response: TokenResponse = try await sendForm(
      url: authBaseURL.appending(path: "oauth/token"),
      items: items
    )
    return CodexCredentials(
      idToken: response.idToken,
      accessToken: response.accessToken,
      refreshToken: response.refreshToken,
      accountID: accountID(from: response.idToken) ?? accountID(from: response.accessToken)
    )
  }

  private func refresh(_ current: CodexCredentials) async throws -> CodexCredentials {
    struct RefreshRequest: Encodable {
      let clientID: String
      let grantType: String
      let refreshToken: String
      enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case grantType = "grant_type"
        case refreshToken = "refresh_token"
      }
    }
    struct RefreshResponse: Decodable {
      let idToken: String?
      let accessToken: String?
      let refreshToken: String?
      enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
      }
    }
    let response: RefreshResponse = try await sendJSON(
      url: authBaseURL.appending(path: "oauth/token"),
      body: RefreshRequest(
        clientID: clientID,
        grantType: "refresh_token",
        refreshToken: current.refreshToken
      )
    )
    guard let accessToken = response.accessToken else {
      throw MobileUsageProviderError.authorizationExpired
    }
    let idToken = response.idToken ?? current.idToken
    let updated = CodexCredentials(
      idToken: idToken,
      accessToken: accessToken,
      refreshToken: response.refreshToken ?? current.refreshToken,
      accountID: accountID(from: idToken) ?? current.accountID
    )
    try keychain.save(updated)
    return updated
  }

  private func fetchUsage(_ credentials: CodexCredentials) async throws -> MobileUsageSnapshot {
    struct UsageResponse: Decodable {
      struct RateLimit: Decodable {
        struct Window: Decodable {
          let usedPercent: Double
          let limitWindowSeconds: Double
          let resetAt: Double
          enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case limitWindowSeconds = "limit_window_seconds"
            case resetAt = "reset_at"
          }
        }
        let primaryWindow: Window?
        let secondaryWindow: Window?
        enum CodingKeys: String, CodingKey {
          case primaryWindow = "primary_window"
          case secondaryWindow = "secondary_window"
        }
      }
      let rateLimit: RateLimit?
      enum CodingKeys: String, CodingKey { case rateLimit = "rate_limit" }
    }
    var request = URLRequest(url: usageURL)
    request.httpMethod = "GET"
    request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("codex-monitor-ios", forHTTPHeaderField: "User-Agent")
    if let accountID = credentials.accountID {
      request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
    }
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw MobileUsageProviderError.invalidServerResponse
    }
    guard (200..<300).contains(http.statusCode) else {
      throw MobileUsageProviderError.requestFailed(http.statusCode)
    }
    let decoded = try JSONDecoder().decode(UsageResponse.self, from: data)
    let windows = [decoded.rateLimit?.primaryWindow, decoded.rateLimit?.secondaryWindow]
      .compactMap { $0 }
    guard let weekly = windows.max(by: { $0.limitWindowSeconds < $1.limitWindowSeconds }) else {
      throw MobileUsageProviderError.invalidServerResponse
    }
    let snapshot = MobileUsageSnapshot(
      usedPercent: weekly.usedPercent,
      resetsAt: Date(timeIntervalSince1970: weekly.resetAt),
      updatedAt: Date()
    )
    try snapshotStore.save(snapshot)
    return snapshot
  }

  private func fetchUsageWithRetry(_ credentials: CodexCredentials) async throws
    -> MobileUsageSnapshot
  {
    var lastError: Error = MobileUsageProviderError.invalidServerResponse
    for attempt in 0..<4 {
      do {
        return try await fetchUsage(credentials)
      } catch {
        guard isTransient(error) else { throw error }
        lastError = error
        if attempt < 3 {
          try await Task.sleep(for: .seconds(Double(attempt + 1)))
        }
      }
    }
    throw lastError
  }

  private func isTransient(_ error: Error) -> Bool {
    if let urlError = error as? URLError {
      return [
        .networkConnectionLost,
        .notConnectedToInternet,
        .timedOut,
        .cannotConnectToHost,
        .dnsLookupFailed,
        .internationalRoamingOff,
        .dataNotAllowed,
      ].contains(urlError.code)
    }
    if case MobileUsageProviderError.requestFailed(let status) = error {
      return status == 408 || status == 425 || status == 429 || (500...599).contains(status)
    }
    return false
  }

  private func tokenExpiresSoon(_ token: String) -> Bool {
    guard let claims = jwtPayload(token), let expiry = claims["exp"] as? TimeInterval else {
      return false
    }
    return Date(timeIntervalSince1970: expiry) < Date().addingTimeInterval(120)
  }

  private func accountID(from token: String) -> String? {
    guard let claims = jwtPayload(token),
      let auth = claims["https://api.openai.com/auth"] as? [String: Any]
    else {
      return nil
    }
    return auth["chatgpt_account_id"] as? String
  }

  private func jwtPayload(_ token: String) -> [String: Any]? {
    let parts = token.split(separator: ".")
    guard parts.count == 3 else { return nil }
    var value = String(parts[1]).replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    value += String(repeating: "=", count: (4 - value.count % 4) % 4)
    guard let data = Data(base64Encoded: value),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return nil
    }
    return json
  }

  private struct TokenResponse: Decodable {
    let idToken: String
    let accessToken: String
    let refreshToken: String
    enum CodingKeys: String, CodingKey {
      case idToken = "id_token"
      case accessToken = "access_token"
      case refreshToken = "refresh_token"
    }
  }

  private func sendJSON<RequestBody: Encodable, ResponseBody: Decodable>(
    url: URL,
    body: RequestBody,
    pendingStatuses: Set<Int> = []
  ) async throws -> ResponseBody? {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(body)
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw MobileUsageProviderError.invalidServerResponse
    }
    if pendingStatuses.contains(http.statusCode) { return nil }
    guard (200..<300).contains(http.statusCode) else {
      throw MobileUsageProviderError.requestFailed(http.statusCode)
    }
    return try JSONDecoder().decode(ResponseBody.self, from: data)
  }

  private func sendJSON<RequestBody: Encodable, ResponseBody: Decodable>(
    url: URL,
    body: RequestBody
  ) async throws -> ResponseBody {
    guard
      let response: ResponseBody = try await sendJSON(
        url: url,
        body: body,
        pendingStatuses: []
      )
    else {
      throw MobileUsageProviderError.invalidServerResponse
    }
    return response
  }

  private func sendForm<ResponseBody: Decodable>(url: URL, items: [URLQueryItem]) async throws
    -> ResponseBody
  {
    var components = URLComponents()
    components.queryItems = items
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw MobileUsageProviderError.invalidServerResponse
    }
    guard (200..<300).contains(http.statusCode) else {
      throw MobileUsageProviderError.requestFailed(http.statusCode)
    }
    return try JSONDecoder().decode(ResponseBody.self, from: data)
  }
}

struct OfficialAccountUsageProvider: MobileUsageProviding {
  func loadUsage() async throws -> MobileUsageSnapshot {
    try await CodexAccountService.shared.loadUsage()
  }
}

struct MobileUsageSnapshotStore: @unchecked Sendable {
  static let appGroupIdentifier = "group.com.example.codexmonitor.mobile"
  private let defaults: UserDefaults?
  private let key = "codex-monitor-mobile-usage-v1"

  init(defaults: UserDefaults? = UserDefaults(suiteName: appGroupIdentifier)) {
    self.defaults = defaults
  }

  func load() -> MobileUsageSnapshot? {
    guard let data = defaults?.data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(MobileUsageSnapshot.self, from: data)
  }

  func save(_ snapshot: MobileUsageSnapshot) throws {
    let data = try JSONEncoder().encode(snapshot)
    defaults?.set(data, forKey: key)
  }
}

struct StoredMobileUsageProvider: MobileUsageProviding {
  private let store: MobileUsageSnapshotStore
  init(store: MobileUsageSnapshotStore = MobileUsageSnapshotStore()) { self.store = store }

  func loadUsage() async throws -> MobileUsageSnapshot {
    guard let snapshot = store.load() else { throw MobileUsageProviderError.noStoredSnapshot }
    return snapshot
  }
}
