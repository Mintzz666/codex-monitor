import Darwin
import Foundation
import SystemConfiguration

public actor CodexAppServerClient {
  private let explicitExecutableURL: URL?
  private let timeout: TimeInterval

  public init(executableURL: URL? = nil, timeout: TimeInterval = 45) {
    explicitExecutableURL = executableURL
    self.timeout = timeout
  }

  public func fetchUsage() async throws -> UsageSnapshot {
    let executableURL = try explicitExecutableURL ?? CodexExecutableLocator.resolve()
    let timeout = timeout
    let deadline = ProcessInfo.processInfo.systemUptime + timeout

    var lastError: Error?
    let configurations = CodexAppServerProbeConfiguration.candidates()

    for (index, configuration) in configurations.enumerated() {
      let remaining = deadline - ProcessInfo.processInfo.systemUptime
      guard remaining > 0 else {
        break
      }
      let credentialIdentity = CredentialIdentity.current()

      // Reserve time for the next attempt instead of letting the first slow
      // connection consume the entire refresh deadline.
      let attemptTimeout = remaining / Double(configurations.count - index)
      do {
        let responses = try await Task.detached(priority: .utility) {
          try CodexAppServerProbe(
            executableURL: executableURL,
            arguments: configuration.arguments,
            environment: configuration.environment
          ).run(timeout: attemptTimeout)
        }.value

        return try decodeUsage(
          from: responses,
          credentialIdentity: credentialIdentity
        )
      } catch {
        lastError = error
        let canRetry =
          index + 1 < configurations.count
          && CodexAppServerProbeConfiguration.shouldRetry(after: error)
        if !canRetry {
          throw error
        }
      }
    }

    throw lastError ?? CodexAppServerClientError.timeout
  }

  private func decodeUsage(
    from responses: [Int: Data],
    credentialIdentity: CredentialIdentity?
  ) throws -> UsageSnapshot {
    guard let accountData = responses[1] else {
      throw CodexAppServerClientError.missingResponse("account/read")
    }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let accountEnvelope = try decoder.decode(
      RPCEnvelope<AccountReadResult>.self,
      from: accountData
    )
    if let error = accountEnvelope.error {
      throw error
    }

    if accountEnvelope.result?.requiresOpenaiAuth == true,
      accountEnvelope.result?.account == nil
    {
      throw CodexAppServerClientError.notSignedIn
    }

    guard let rateLimitsData = responses[2] else {
      throw CodexAppServerClientError.missingResponse("account/rateLimits/read")
    }

    let rateLimitsEnvelope = try decoder.decode(
      RPCEnvelope<RateLimitsReadResult>.self,
      from: rateLimitsData
    )
    if let error = rateLimitsEnvelope.error {
      throw error
    }
    guard let rateLimits = rateLimitsEnvelope.result else {
      throw CodexAppServerClientError.missingResult("account/rateLimits/read")
    }

    let rawQuotaResult = responses[2].flatMap(parseRawQuotaResult)
    if let credentialIdentity, let rawQuotaResult {
      let accountIDValues = rawQuotaResult.accountIDValues
      if accountIDValues.compactMap({ $0 }).contains(where: {
        !credentialIdentity.matchesQuotaAccountID($0)
      }) {
        throw CredentialIdentityError.accountChanged
      }
    }

    let selected = try WeeklyUsageSelector.select(
      from: rateLimits,
      accountPlanType: accountEnvelope.result?.account?.planType
    )

    let tokenUsage: TokenUsage?
    if let usageData = responses[3],
      let usageEnvelope = try? decoder.decode(
        RPCEnvelope<AccountUsageReadResult>.self,
        from: usageData
      ),
      usageEnvelope.error == nil,
      let usage = usageEnvelope.result
    {
      tokenUsage = TokenUsage(
        lifetimeTokens: usage.summary?.lifetimeTokens,
        peakDailyTokens: usage.summary?.peakDailyTokens,
        currentStreakDays: usage.summary?.currentStreakDays,
        dailyBuckets: (usage.dailyUsageBuckets ?? []).map {
          DailyTokenUsage(startDate: $0.startDate, tokens: $0.tokens)
        }
      )
    } else {
      tokenUsage = nil
    }
    return try usageSnapshot(
      selected,
      tokenUsage: tokenUsage,
      credentialIdentity: credentialIdentity,
      rawQuotaResult: rawQuotaResult
    )
  }

  private func usageSnapshot(
    _ selected: UsageSnapshot,
    tokenUsage: TokenUsage?,
    credentialIdentity: CredentialIdentity?,
    rawQuotaResult: RawQuotaResult?
  ) throws -> UsageSnapshot {
    var snapshot = selected.attaching(tokenUsage: tokenUsage)

    if let credentialIdentity {
      if let rawQuotaResult,
        rawQuotaResult.accountIDFieldCount > 0,
        rawQuotaResult.accountIDValues.count == rawQuotaResult.accountIDFieldCount,
        rawQuotaResult.accountIDValues.allSatisfy({ $0 != nil }),
        rawQuotaResult.accountIDValues.allSatisfy({
          $0.map(credentialIdentity.matchesQuotaAccountID) ?? false
        }),
        let sanitizedJSON = rawQuotaResult.sanitizedJSON
      {
        snapshot = snapshot.attaching(
          accountFingerprint: credentialIdentity.fingerprint,
          rateLimitsJSON: sanitizedJSON
        )
      }

      guard CredentialIdentity.currentFingerprint() == credentialIdentity.fingerprint
      else {
        throw CredentialIdentityError.accountChanged
      }
    }

    return snapshot
  }
}

private struct RawQuotaResult {
  let accountIDFieldCount: Int
  let accountIDValues: [String?]
  let sanitizedJSON: String?
}

private func parseRawQuotaResult(from responseData: Data) -> RawQuotaResult? {
  guard let response = try? JSONSerialization.jsonObject(with: responseData)
    as? [String: Any],
    var result = response["result"] as? [String: Any]
  else {
    return nil
  }

  let accountIDKeys = ["accountId", "account_id"].filter {
    result[$0] != nil
  }
  let accountIDValues = accountIDKeys.map { result[$0] as? String }
  for key in accountIDKeys {
    result.removeValue(forKey: key)
  }
  guard let sanitizedData = try? JSONSerialization.data(
    withJSONObject: result,
    options: [.sortedKeys]
  ), let sanitizedJSON = String(data: sanitizedData, encoding: .utf8) else {
    return nil
  }

  return RawQuotaResult(
    accountIDFieldCount: accountIDKeys.count,
    accountIDValues: accountIDValues,
    sanitizedJSON: sanitizedJSON
  )
}

private struct CodexAppServerProbeConfiguration: Sendable {
  let arguments: [String]
  let environment: [String: String]

  static func candidates() -> [Self] {
    // Finder/login-item launches do not inherit shell proxy variables. Read
    // the current macOS proxy on every refresh so Clash port changes apply
    // without hard-coding a port or changing the user's global routing.
    let environment = CodexAppServerProcessEnvironment.resolve()
    // Keep the current flag first, then support the equivalent transport form
    // used by newer Codex CLI builds.
    let argumentVariants = [
      ["app-server", "--stdio"],
      ["app-server", "--listen", "stdio://"],
    ]

    return argumentVariants.map { arguments in
      Self(arguments: arguments, environment: environment)
    }
  }

  static func shouldRetry(after error: Error) -> Bool {
    if let rpcError = error as? RPCErrorPayload {
      let message = rpcError.message.lowercased()
      if ["unauthorized", "forbidden", "not signed in", "401", "403"]
        .contains(where: message.contains)
      {
        return false
      }
      // -32603 is the app-server's usual upstream transport wrapper. The
      // -320xx range includes transient server overload responses.
      return rpcError.code == -32603
        || (-32099...(-32000)).contains(rpcError.code)
    }

    switch error {
    case CodexAppServerClientError.timeout,
      CodexAppServerClientError.terminated,
      CodexAppServerClientError.invalidProtocol:
      return true
    case CredentialIdentityError.accountChanged:
      return true
    default:
      return false
    }
  }
}

public enum CodexAppServerProcessEnvironment {
  public static func resolve(
    base: [String: String] = ProcessInfo.processInfo.environment,
    systemProxies: [String: Any]? = nil
  ) -> [String: String] {
    let settings = systemProxies
      ?? (SCDynamicStoreCopyProxies(nil) as? [String: Any] ?? [:])
    var updated = base
    for key in ["http_proxy", "https_proxy", "all_proxy", "no_proxy"] {
      // reqwest/curl-style clients prefer lowercase. Keep both forms equal
      // so subprocesses cannot accidentally select conflicting routes.
      if let value = base[key] ?? base[key.uppercased()] {
        updated[key] = value
        updated[key.uppercased()] = value
      }
    }

    if updated["all_proxy"] == nil {
      for (key, prefix) in [("http_proxy", "HTTP"), ("https_proxy", "HTTPS")] {
        if updated[key] == nil,
          let proxy = proxyURL(prefix: prefix, scheme: "http", settings: settings)
        {
          updated[key] = proxy
          updated[key.uppercased()] = proxy
        }
      }
      if updated["http_proxy"] == nil, updated["https_proxy"] == nil,
        let proxy = proxyURL(prefix: "SOCKS", scheme: "socks5h", settings: settings)
      {
        updated["all_proxy"] = proxy
        updated["ALL_PROXY"] = proxy
      }
    }

    if ["http_proxy", "https_proxy", "all_proxy"].contains(where: {
      !(updated[$0] ?? "").isEmpty
    }) {
      var exceptions = (updated["no_proxy"] ?? "")
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
      let systemExceptions = (settings["ExceptionsList"] as? [String] ?? [])
        .filter { $0 != "<local>" }
        .map { $0.hasPrefix("*.") ? String($0.dropFirst()) : $0 }
      for host in ["localhost", "127.0.0.1", "::1"] + systemExceptions
        where !exceptions.contains(host)
      {
        exceptions.append(host)
      }
      updated["no_proxy"] = exceptions.joined(separator: ",")
      updated["NO_PROXY"] = updated["no_proxy"]
    }
    return updated
  }

  private static func proxyURL(
    prefix: String, scheme: String, settings: [String: Any]
  ) -> String? {
    guard (settings["\(prefix)Enable"] as? NSNumber)?.intValue == 1,
      let rawHost = settings["\(prefix)Proxy"] as? String,
      let port = (settings["\(prefix)Port"] as? NSNumber)?.intValue,
      (1...65_535).contains(port)
    else { return nil }
    let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !host.isEmpty,
      host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
      host.rangeOfCharacter(from: CharacterSet(charactersIn: "/@?#")) == nil
    else { return nil }
    var components = URLComponents()
    components.scheme = scheme
    components.host = host
    components.port = port
    return components.url?.absoluteString
  }
}

enum CodexAppServerClientError: LocalizedError {
  case launchFailed(String)
  case timeout
  case terminated(Int32)
  case missingResponse(String)
  case missingResult(String)
  case notSignedIn
  case invalidProtocol

  var errorDescription: String? {
    switch self {
    case .launchFailed(let message):
      return "启动 Codex app-server 失败：\(message)"
    case .timeout:
      return "读取 Codex 限额超时"
    case .terminated(let status):
      return "Codex app-server 已退出，状态码：\(status)"
    case .missingResponse(let method):
      return "Codex app-server 未返回 \(method)"
    case .missingResult(let method):
      return "Codex app-server 的 \(method) 响应缺少结果"
    case .notSignedIn:
      return "Codex 当前未登录 ChatGPT"
    case .invalidProtocol:
      return "Codex app-server 返回了无法解析的数据"
    }
  }
}

private struct RPCResponseHeader: Decodable {
  let id: Int?
  let error: RPCErrorPayload?
}

private struct CodexAppServerProbe: Sendable {
  let executableURL: URL
  let arguments: [String]
  let environment: [String: String]

  func run(timeout: TimeInterval) throws -> [Int: Data] {
    let process = Process()
    let standardInput = Pipe()
    let standardOutput = Pipe()

    process.executableURL = executableURL
    process.arguments = arguments
    process.environment = environment
    process.standardInput = standardInput
    process.standardOutput = standardOutput
    process.standardError = FileHandle.nullDevice

    do {
      try process.run()
    } catch {
      throw CodexAppServerClientError.launchFailed(error.localizedDescription)
    }

    let inputHandle = standardInput.fileHandleForWriting
    let outputHandle = standardOutput.fileHandleForReading

    defer {
      try? inputHandle.close()
      try? outputHandle.close()
      stop(process)
    }

    write(
      "{\"method\":\"initialize\",\"id\":0,\"params\":{\"clientInfo\":{\"name\":\"codex-monitor\",\"title\":\"Codex Monitor\",\"version\":\"0.1.0\"}}}\n",
      to: inputHandle
    )

    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    var buffer = Data()
    var responses: [Int: Data] = [:]
    let outputDescriptor = outputHandle.fileDescriptor
    let currentFlags = fcntl(outputDescriptor, F_GETFL)
    guard currentFlags >= 0,
      fcntl(outputDescriptor, F_SETFL, currentFlags | O_NONBLOCK) >= 0
    else {
      throw CodexAppServerClientError.invalidProtocol
    }
    var descriptor = pollfd(
      fd: outputDescriptor,
      events: Int16(POLLIN | POLLHUP | POLLERR),
      revents: 0
    )
    var didSendInitialized = false
    var didSendAccountDataRequests = false
    var rateLimitsReceivedAt: TimeInterval?
    var didRetryRateLimitParameters = false

    while ProcessInfo.processInfo.systemUptime < deadline {
      let remainingMilliseconds = max(
        1,
        min(250, Int((deadline - ProcessInfo.processInfo.systemUptime) * 1_000))
      )
      descriptor.revents = 0
      let pollResult = Darwin.poll(&descriptor, 1, Int32(remainingMilliseconds))

      if pollResult < 0 {
        if errno == EINTR {
          continue
        }
        throw CodexAppServerClientError.invalidProtocol
      }

      if pollResult > 0,
        descriptor.revents & Int16(POLLIN | POLLHUP) != 0
      {
        var bytes = [UInt8](repeating: 0, count: 16_384)
        let byteCount = bytes.withUnsafeMutableBytes {
          Darwin.read(outputDescriptor, $0.baseAddress, $0.count)
        }
        if byteCount > 0 {
          buffer.append(contentsOf: bytes.prefix(byteCount))
          try consumeLines(from: &buffer, into: &responses)
        } else if byteCount < 0, errno != EAGAIN, errno != EWOULDBLOCK,
          errno != EINTR
        {
          throw CodexAppServerClientError.invalidProtocol
        }
      }

      if responses[0] != nil, !didSendInitialized {
        write(
          "{\"method\":\"initialized\",\"params\":{}}\n"
            + "{\"method\":\"account/read\",\"id\":1,\"params\":{\"refreshToken\":false}}\n",
          to: inputHandle
        )
        didSendInitialized = true
      }

      if responses[1] != nil, !didSendAccountDataRequests {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let account = try decoder.decode(RPCEnvelope<AccountReadResult>.self, from: responses[1]!)
        if let error = account.error { throw error }
        if account.result?.requiresOpenaiAuth == true, account.result?.account == nil {
          throw CodexAppServerClientError.notSignedIn
        }
        write(
          // Quota polling does not display reset-credit details. Avoid the
          // separate upstream lookup (and its independent timeout).
          "{\"method\":\"account/rateLimits/read\",\"id\":2,\"params\":{\"excludeResetCreditDetails\":true}}\n"
            + "{\"method\":\"account/usage/read\",\"id\":3}\n",
          to: inputHandle
        )
        didSendAccountDataRequests = true
      }

      if let data = responses[2] {
        let header = try JSONDecoder().decode(RPCResponseHeader.self, from: data)
        if let error = header.error {
          if error.code == -32602, !didRetryRateLimitParameters {
            // Older CLI builds may not accept the background-poll parameter.
            didRetryRateLimitParameters = true
            responses.removeValue(forKey: 2)
            write("{\"method\":\"account/rateLimits/read\",\"id\":2}\n", to: inputHandle)
          } else {
            throw error
          }
        } else if rateLimitsReceivedAt == nil {
          rateLimitsReceivedAt = ProcessInfo.processInfo.systemUptime
        }
      }

      if responses[1] != nil, responses[2] != nil {
        if responses[3] != nil {
          return responses
        }
        if let rateLimitsReceivedAt,
          ProcessInfo.processInfo.systemUptime - rateLimitsReceivedAt >= 2
        {
          return responses
        }
      }

      if !process.isRunning {
        if responses[1] != nil, responses[2] != nil {
          return responses
        }
        throw CodexAppServerClientError.terminated(process.terminationStatus)
      }
    }

    // Token activity is optional; a slow optional request must not discard a
    // valid quota response that arrived just before the deadline.
    if responses[1] != nil, responses[2] != nil {
      return responses
    }
    throw CodexAppServerClientError.timeout
  }

  private func write(
    _ payload: String,
    to handle: FileHandle
  ) {
    do {
      try handle.write(contentsOf: Data(payload.utf8))
    } catch {
      // The read loop will surface the process termination or timeout with a
      // more useful app-server error if the child exits while writing.
    }
  }

  private func consumeLines(
    from buffer: inout Data,
    into responses: inout [Int: Data]
  ) throws {
    while let newlineIndex = buffer.firstIndex(of: 0x0A) {
      let line = Data(buffer[..<newlineIndex])
      buffer.removeSubrange(...newlineIndex)

      guard !line.isEmpty else {
        continue
      }

      let header: RPCResponseHeader
      do {
        header = try JSONDecoder().decode(RPCResponseHeader.self, from: line)
      } catch {
        continue
      }

      if header.id == 0, let error = header.error {
        throw error
      }
      if let id = header.id, (0...3).contains(id) {
        responses[id] = line
      }
    }
  }

  private func stop(_ process: Process) {
    guard process.isRunning else {
      return
    }

    process.terminate()
    let gracefulDeadline = Date().addingTimeInterval(1)
    while process.isRunning, Date() < gracefulDeadline {
      usleep(10_000)
    }
    if process.isRunning {
      kill(process.processIdentifier, SIGKILL)
    }
    process.waitUntilExit()
  }
}
