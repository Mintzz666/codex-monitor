import CodexUsageCore
import Darwin
import Foundation

enum NetworkChecks {
  static func run() async throws {
    try checkSystemHTTPAndHTTPSProxies()
    try checkExplicitProxyCaseNormalization()
    try checkDisabledAndInvalidSystemProxies()
    try checkSOCKSOnlyProxy()

    try await checkTimeoutIsSharedAcrossAttempts()
    try await checkTransientRPCErrorRetries()
    try await checkNotSignedInDoesNotRetry()
    try await checkMissingOptionalUsageDoesNotDelayQuota()
    try await checkInvalidParamsFallsBackInSameProcess()
  }

  private static func checkSystemHTTPAndHTTPSProxies() throws {
    let resolved = CodexAppServerProcessEnvironment.resolve(
      base: ["PATH": "/usr/bin:/bin", "NO_PROXY": "intranet.example"],
      systemProxies: [
        "HTTPEnable": 1,
        "HTTPProxy": "proxy.example",
        "HTTPPort": 8080,
        "HTTPSEnable": 1,
        "HTTPSProxy": "secure-proxy.example",
        "HTTPSPort": 8443,
      ]
    )

    let exceptions = noProxyEntries(in: resolved)
    try expect(
      resolved["HTTP_PROXY"] == "http://proxy.example:8080"
        && resolved["http_proxy"] == "http://proxy.example:8080"
        && resolved["HTTPS_PROXY"] == "http://secure-proxy.example:8443"
        && resolved["https_proxy"] == "http://secure-proxy.example:8443"
        && Set(exceptions).isSuperset(of: [
        "intranet.example", "localhost", "127.0.0.1", "::1",
      ])
        && exceptions.allSatisfy {
          !$0.contains("*")
            && !$0.localizedCaseInsensitiveContains("chatgpt")
            && !$0.localizedCaseInsensitiveContains("openai")
        },
      "注入系统 HTTP/HTTPS 代理、保留 NO_PROXY 并只绕过 loopback"
    )
  }

  private static func checkExplicitProxyCaseNormalization() throws {
    let resolved = CodexAppServerProcessEnvironment.resolve(
      base: [
        "PATH": "/usr/bin:/bin",
        "HTTP_PROXY": "http://upper.example:8000",
        "http_proxy": "http://lower.example:9000",
        "HTTPS_PROXY": "http://secure.example:9443",
        "NO_PROXY": "existing-entry.example",
      ],
      systemProxies: [
        "HTTPEnable": 1,
        "HTTPProxy": "system-http.example",
        "HTTPPort": 18080,
        "HTTPSEnable": 1,
        "HTTPSProxy": "system-https.example",
        "HTTPSPort": 18443,
      ]
    )

    try expect(
      resolved["HTTP_PROXY"] == "http://lower.example:9000"
        && resolved["http_proxy"] == "http://lower.example:9000"
        && resolved["HTTPS_PROXY"] == "http://secure.example:9443"
        && resolved["https_proxy"] == "http://secure.example:9443"
        && noProxyEntries(in: resolved).contains("existing-entry.example"),
      "小写显式代理优先、压过系统设置并保留已有 NO_PROXY"
    )
  }

  private static func checkDisabledAndInvalidSystemProxies() throws {
    let resolved = CodexAppServerProcessEnvironment.resolve(
      base: ["PATH": "/usr/bin:/bin"],
      systemProxies: [
        "HTTPEnable": 0,
        "HTTPProxy": "unused.example",
        "HTTPPort": 7897,
        "HTTPSEnable": 1,
        "HTTPSProxy": "",
        "HTTPSPort": 443,
        "SOCKSEnable": 1,
        "SOCKSProxy": "socks.example",
        "SOCKSPort": 0,
      ]
    )

    let proxyKeys = [
      "HTTP_PROXY", "http_proxy", "HTTPS_PROXY", "https_proxy",
      "ALL_PROXY", "all_proxy",
    ]
    try expect(
      proxyKeys.allSatisfy { resolved[$0] == nil }
        && !resolved.values.contains(where: { $0.contains("7897") }),
      "系统代理未启用或 host/port 无效时不注入代理，也不硬编码 7897"
    )
  }

  private static func checkSOCKSOnlyProxy() throws {
    let resolved = CodexAppServerProcessEnvironment.resolve(
      base: ["PATH": "/usr/bin:/bin"],
      systemProxies: [
        "SOCKSEnable": 1,
        "SOCKSProxy": "socks.example",
        "SOCKSPort": 1080,
      ]
    )

    try expect(
      resolved["ALL_PROXY"] == "socks5h://socks.example:1080"
        && resolved["all_proxy"] == "socks5h://socks.example:1080"
        && resolved["HTTP_PROXY"] == nil
        && resolved["HTTPS_PROXY"] == nil,
      "仅启用 SOCKS 时注入 socks5h ALL_PROXY"
    )
  }

  private static func checkTimeoutIsSharedAcrossAttempts() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let launchCount = directory.appendingPathComponent("launch-count")
    let argumentLog = directory.appendingPathComponent("arguments.log")
    let executable = try makeExecutable(
      named: "codex-timeout",
      in: directory,
      body: counterPreamble(at: launchCount)
        + """
        printf '%s %s\\n' "${2-}" "${3-}" >> \(shellQuote(argumentLog.path))
        if [ "$count" -eq 1 ] && [ "${2-}" = "--stdio" ]; then
          exec /bin/sleep 8
        fi
        if [ "${2-}" = "--listen" ] && [ "${3-}" != "stdio://" ]; then
          exit 65
        fi
        \(successfulRPCLoop)
        """
    )

    let startedAt = Date()
    let snapshot = try await CodexAppServerClient(
      executableURL: executable,
      timeout: 2
    ).fetchUsage()
    let elapsed = Date().timeIntervalSince(startedAt)
    let arguments = (try String(contentsOf: argumentLog, encoding: .utf8))
      .split(whereSeparator: \.isNewline)
      .map(String.init)

    try expect(
      snapshot.usedPercent == 12.5
        && readInteger(at: launchCount) == 2
        && arguments.first == "--stdio "
        && arguments.last == "--listen stdio://"
        && elapsed < 2.8,
      "超时后按 --stdio、--listen 顺序重试且共享约 2 秒预算"
    )
  }

  private static func checkTransientRPCErrorRetries() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let firstRateLimitRequest = directory.appendingPathComponent("rate-limit-first")
    let executable = try makeExecutable(
      named: "codex-transient",
      in: directory,
      body: """
        while IFS= read -r line; do
          case "$line" in
            *'"method":"initialize"'*)
              printf '%s\\n' '{"id":0,"result":{}}'
              ;;
            *'"method":"account/read"'*)
              printf '%s\\n' '\(accountReply)'
              ;;
            *'"method":"account/rateLimits/read"'*)
              if [ ! -f \(shellQuote(firstRateLimitRequest.path)) ]; then
                : > \(shellQuote(firstRateLimitRequest.path))
                printf '%s\\n' '{"id":2,"error":{"code":-32603,"message":"temporary upstream failure"}}'
              else
                printf '%s\\n' '\(rateLimitsReply)'
              fi
              ;;
            *'"method":"account/usage/read"'*)
              printf '%s\\n' '{"id":3,"result":{}}'
              ;;
          esac
        done
        """
    )

    let snapshot = try await CodexAppServerClient(
      executableURL: executable,
      timeout: 2
    ).fetchUsage()
    try expect(
      snapshot.usedPercent == 12.5
        && FileManager.default.fileExists(atPath: firstRateLimitRequest.path),
      "-32603 transient RPC 错误后重试并取得限额"
    )
  }

  private static func checkNotSignedInDoesNotRetry() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let launchCount = directory.appendingPathComponent("launch-count")
    let executable = try makeExecutable(
      named: "codex-not-signed-in",
      in: directory,
      body: counterPreamble(at: launchCount)
        + """
        while IFS= read -r line; do
          case "$line" in
            *'"method":"initialize"'*)
              printf '%s\\n' '{"id":0,"result":{}}'
              ;;
            *'"method":"account/read"'*)
              printf '%s\\n' '\(notSignedInAccountReply)'
              exec /bin/sleep 8
              ;;
          esac
        done
        """
    )

    let startedAt = Date()
    var errorMessage: String?
    do {
      _ = try await CodexAppServerClient(
        executableURL: executable,
        timeout: 1.5
      ).fetchUsage()
    } catch {
      errorMessage = error.localizedDescription
    }
    let elapsed = Date().timeIntervalSince(startedAt)

    try expect(
      errorMessage?.localizedCaseInsensitiveContains("登录") == true
        && readInteger(at: launchCount) == 1
        && elapsed < 1.1,
      "account/read 返回未登录时尽早失败且不重启进程"
    )
  }

  private static func checkMissingOptionalUsageDoesNotDelayQuota() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let executable = try makeExecutable(
      named: "codex-no-optional-usage",
      in: directory,
      body: """
        while IFS= read -r line; do
          case "$line" in
            *'"method":"initialize"'*)
              printf '%s\\n' '{"id":0,"result":{}}'
              ;;
            *'"method":"account/read"'*)
              printf '%s\\n' '\(accountReply)'
              ;;
            *'"method":"account/rateLimits/read"'*)
              printf '%s\\n' '\(rateLimitsReply)'
              ;;
          esac
        done
        """
    )

    let startedAt = Date()
    let snapshot = try await CodexAppServerClient(
      executableURL: executable,
      timeout: 3
    ).fetchUsage()
    let elapsed = Date().timeIntervalSince(startedAt)

    try expect(
      snapshot.usedPercent == 12.5 && elapsed < 2.5,
      "可选 account/usage/read 未返回时及时交付已收到的 quota"
    )
  }

  private static func checkInvalidParamsFallsBackInSameProcess() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let launchCount = directory.appendingPathComponent("launch-count")
    let parameterMarker = directory.appendingPathComponent("params-sent")
    let fallbackMarker = directory.appendingPathComponent("fallback-sent")
    let executable = try makeExecutable(
      named: "codex-params-fallback",
      in: directory,
      body: counterPreamble(at: launchCount)
        + """
        while IFS= read -r line; do
          case "$line" in
            *'"method":"initialize"'*)
              printf '%s\\n' '{"id":0,"result":{}}'
              ;;
            *'"method":"account/read"'*)
              printf '%s\\n' '\(accountReply)'
              ;;
            *excludeResetCreditDetails*)
              : > \(shellQuote(parameterMarker.path))
              printf '%s\\n' '{"id":2,"error":{"code":-32602,"message":"invalid params"}}'
              ;;
            *'"method":"account/rateLimits/read"'*)
              : > \(shellQuote(fallbackMarker.path))
              printf '%s\\n' '\(rateLimitsReply)'
              ;;
            *'"method":"account/usage/read"'*)
              printf '%s\\n' '{"id":3,"result":{}}'
              ;;
          esac
        done
        """
    )

    let snapshot = try await CodexAppServerClient(
      executableURL: executable,
      timeout: 2
    ).fetchUsage()

    try expect(
      snapshot.usedPercent == 12.5
        && FileManager.default.fileExists(atPath: parameterMarker.path)
        && FileManager.default.fileExists(atPath: fallbackMarker.path)
        && readInteger(at: launchCount) == 1,
      "-32602 后无 params 同进程回退并成功"
    )
  }

  private static let accountReply =
    "{\"id\":1,\"result\":{\"account\":{\"type\":\"chatgpt\",\"planType\":\"pro\"},\"requiresOpenaiAuth\":true}}"

  private static let notSignedInAccountReply =
    "{\"id\":1,\"result\":{\"account\":null,\"requiresOpenaiAuth\":true}}"

  private static let rateLimitsReply =
    "{\"id\":2,\"result\":{\"rateLimits\":{\"limitId\":\"codex\",\"planType\":\"pro\",\"primary\":{\"usedPercent\":12.5,\"windowDurationMins\":10080,\"resetsAt\":1893456000}}}}"

  private static let successfulRPCLoop = """
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*)
          printf '%s\\n' '{"id":0,"result":{}}'
          ;;
        *'"method":"account/read"'*)
          printf '%s\\n' '\(accountReply)'
          ;;
        *'"method":"account/rateLimits/read"'*)
          printf '%s\\n' '\(rateLimitsReply)'
          ;;
        *'"method":"account/usage/read"'*)
          printf '%s\\n' '{"id":3,"result":{}}'
          ;;
      esac
    done
    """

  private static func counterPreamble(at url: URL) -> String {
    let quotedPath = shellQuote(url.path)
    return """
      count=0
      if [ -f \(quotedPath) ]; then
        IFS= read -r count < \(quotedPath) || count=0
      fi
      count=$((count + 1))
      printf '%s\\n' "$count" > \(quotedPath)
      """ + "\n"
  }

  private static func makeExecutable(
    named name: String,
    in directory: URL,
    body: String
  ) throws -> URL {
    let executable = directory.appendingPathComponent(name)
    try Data(("#!/bin/sh\nset -u\n" + body + "\n").utf8)
      .write(to: executable)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: executable.path
    )
    return executable
  }

  private static func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("CodexNetworkChecks-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    return directory
  }

  private static func readInteger(at url: URL) -> Int? {
    guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
      return nil
    }
    return Int(contents.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  private static func noProxyEntries(in environment: [String: String]) -> [String] {
    let value = environment["NO_PROXY"] ?? environment["no_proxy"] ?? ""
    return value.split(separator: ",").map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  private static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  private static func expect(_ condition: @autoclosure () -> Bool, _ label: String) throws {
    guard condition() else {
      throw NetworkCheckFailure.assertion(label)
    }
    print("PASS \(label)")
  }
}

private enum NetworkCheckFailure: LocalizedError {
  case assertion(String)

  var errorDescription: String? {
    switch self {
    case .assertion(let message):
      return "NetworkChecks 失败：\(message)"
    }
  }
}
