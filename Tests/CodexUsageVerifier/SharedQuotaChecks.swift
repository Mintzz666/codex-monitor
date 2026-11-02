import CodexUsageCore
import CodexUsageShared
import Darwin
import Foundation

enum SharedQuotaChecks {
  static func run() async throws {
    try checkFingerprintVector()
    try checkCredentialIdentityLoading()
    try checkLegacySnapshotDecoding()
    try await checkQuotaMetadataAndSanitization()
    try await checkAccountMismatchIsRejected()
    try await checkAccountChangeRetriesWithFreshIdentity()
    try await checkUnverifiableQuotaIsDisplayOnly()
  }

  private static func checkFingerprintVector() throws {
    try check(
      CredentialIdentity.fingerprint(
        canonicalCodexHome: "/tmp/example",
        accountID: "example-account"
      ) == "29ad60ec2bf92ac3140ac1dfaa43f7c1c2f6edad15120a2ee18edf482f97bb8c",
      "共享账号指纹匹配固定 SHA-256 跨语言向量"
    )
  }

  private static func checkCredentialIdentityLoading() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("codex-home", isDirectory: true)
    let alias = root.appendingPathComponent("home-alias", isDirectory: true)
    try FileManager.default.createDirectory(
      at: home,
      withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(
      atPath: alias.path,
      withDestinationPath: home.path
    )
    let authURL = home.appendingPathComponent("auth.json")
    let previousHome = try setCodexHome(alias.path)
    defer { restoreCodexHome(previousHome) }

    try writeAuth(accountID: "first-account", to: authURL)
    let expectedHome = URL(fileURLWithPath: home.path, isDirectory: true)
      .standardizedFileURL.resolvingSymlinksInPath().path
    let firstFingerprint = CredentialIdentity.currentFingerprint()
    try check(
      firstFingerprint == CredentialIdentity.fingerprint(
        canonicalCodexHome: expectedHome,
        accountID: "first-account"
      ),
      "只从 ChatGPT auth account_id 生成指纹并解析 CODEX_HOME 符号链接"
    )
    try check(
      firstFingerprint?.contains("first-account") == false,
      "账号指纹不包含可读账号 ID"
    )

    try writeAuth(accountID: "second-account", to: authURL)
    try check(
      CredentialIdentity.currentFingerprint() != firstFingerprint,
      "auth account_id 变化会改变账号指纹"
    )

    try Data(
      #"{"auth_mode":"api_key","tokens":{"account_id":"first-account"}}"#.utf8
    ).write(to: authURL)
    try check(
      CredentialIdentity.currentFingerprint() == nil,
      "非 ChatGPT auth_mode 不生成共享身份"
    )

    try Data(
      #"{"auth_mode":"chatgpt","tokens":{"account_id":"  "}}"#.utf8
    ).write(to: authURL)
    try check(
      CredentialIdentity.currentFingerprint() == nil,
      "空 account_id fail-closed"
    )

    try Data(#"{"auth_mode":"chatgpt","account_id":"root-account"}"#.utf8)
      .write(to: authURL)
    try check(
      CredentialIdentity.currentFingerprint() == CredentialIdentity.fingerprint(
        canonicalCodexHome: expectedHome,
        accountID: "root-account"
      ),
      "兼容 auth.json 根级 account_id"
    )
  }

  private static func checkLegacySnapshotDecoding() throws {
    let legacy = try JSONDecoder().decode(
      SharedUsageSnapshot.self,
      from: Data(
        #"{"usedPercent":12.5,"updatedAt":782592051}"#.utf8
      )
    )
    try check(
      legacy.accountFingerprint == nil
        && legacy.rateLimitsJSON == nil
        && legacy.quotaSourceVersion == nil,
      "兼容不含共享账号元数据的旧快照"
    )
  }

  private static func checkQuotaMetadataAndSanitization() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("codex-home", isDirectory: true)
    try FileManager.default.createDirectory(
      at: home,
      withIntermediateDirectories: true
    )
    try writeAuth(
      accountID: "verified-account",
      to: home.appendingPathComponent("auth.json")
    )
    let previousHome = try setCodexHome(home.path)
    defer { restoreCodexHome(previousHome) }

    let quota = #"{"id":2,"result":{"accountId":"verified-account","account_id":"verified-account","rateLimits":{"limitId":"codex","primary":{"usedPercent":12.345678901234567,"windowDurationMins":10080,"resetsAt":1893456000}},"resetCredits":{"total":5,"resetsAt":1893456000},"resetCount":7}}"#
    let snapshot = try await CodexAppServerClient(
      executableURL: try makeQuotaExecutable(
        in: root,
        quotaReply: quota
      ),
      timeout: 3
    ).fetchUsage()
    let canonicalHome = URL(fileURLWithPath: home.path, isDirectory: true)
      .standardizedFileURL.resolvingSymlinksInPath().path
    try check(
      snapshot.accountFingerprint == CredentialIdentity.fingerprint(
        canonicalCodexHome: canonicalHome,
        accountID: "verified-account"
      )
        && snapshot.rateLimitsJSON != nil,
      "quota accountId 与 credential 匹配后附加共享 metadata"
    )
    let sharedQuota = snapshot.rateLimitsJSON ?? ""
    let sharedQuotaObject = try JSONSerialization.jsonObject(
      with: Data(sharedQuota.utf8)
    ) as? [String: Any]
    let sharedRateLimits = sharedQuotaObject?["rateLimits"] as? [String: Any]
    let sharedPrimary = sharedRateLimits?["primary"] as? [String: Any]
    let sharedResetCredits = sharedQuotaObject?["resetCredits"] as? [String: Any]
    try check(
      !sharedQuota.contains("accountId")
        && !sharedQuota.contains("account_id")
        && sharedQuotaObject?["id"] == nil
        && sharedPrimary?["usedPercent"] as? Double == 12.345678901234567
        && sharedPrimary?["windowDurationMins"] as? Int == 10_080
        && sharedPrimary?["resetsAt"] as? Int == 1_893_456_000
        && sharedResetCredits?["total"] as? Int == 5
        && sharedQuotaObject?["resetCount"] as? Int == 7,
      "只脱敏 quota 顶层账号 ID，保留窗口精度、重置时间和 resetCredits"
    )

    let attachedTokens = snapshot.attaching(tokenUsage: nil)
    try check(
      attachedTokens.accountFingerprint == snapshot.accountFingerprint
        && attachedTokens.rateLimitsJSON == snapshot.rateLimitsJSON,
      "附加 Token 统计时保留 quota metadata"
    )

    let shared = SharedUsageSnapshot(
      usedPercent: snapshot.usedPercent,
      resetsAt: snapshot.resetsAt,
      planType: snapshot.planType,
      limitName: snapshot.limitName,
      updatedAt: Date(timeIntervalSince1970: 1_893_456_000),
      accountFingerprint: snapshot.accountFingerprint,
      rateLimitsJSON: snapshot.rateLimitsJSON,
      quotaSourceVersion: 1
    )
    let encoded = try JSONEncoder().encode(shared)
    let encodedObject = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    let decoded = try JSONDecoder().decode(SharedUsageSnapshot.self, from: encoded)
    try check(
      decoded == shared
        && encodedObject?["accountFingerprint"] as? String == snapshot.accountFingerprint
        && encodedObject?["quotaSourceVersion"] as? Int == 1,
      "SharedUsageSnapshot 编解码保留可信 quota metadata"
    )
    try check(
      encoded.count <= LocalUsageSnapshotBridgeConfiguration.maximumPayloadSize,
      "共享 metadata 快照处于 64 KiB loopback payload 预算内"
    )
  }

  private static func checkAccountMismatchIsRejected() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("codex-home", isDirectory: true)
    try FileManager.default.createDirectory(
      at: home,
      withIntermediateDirectories: true
    )
    try writeAuth(
      accountID: "credential-account",
      to: home.appendingPathComponent("auth.json")
    )
    let previousHome = try setCodexHome(home.path)
    defer { restoreCodexHome(previousHome) }

    do {
      _ = try await CodexAppServerClient(
        executableURL: try makeQuotaExecutable(
          in: root,
          quotaReply: quotaReply(accountID: "different-account")
        ),
        timeout: 3
      ).fetchUsage()
      throw SharedQuotaVerificationFailure("错误账号的 quota 响应未被拒绝")
    } catch CredentialIdentityError.accountChanged {
      try check(true, "quota accountId 与当前 credential 不同则拒绝额度数据")
    }
  }

  private static func checkAccountChangeRetriesWithFreshIdentity() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("codex-home", isDirectory: true)
    try FileManager.default.createDirectory(
      at: home,
      withIntermediateDirectories: true
    )
    let authURL = home.appendingPathComponent("auth.json")
    try writeAuth(accountID: "first-account", to: authURL)
    let previousHome = try setCodexHome(home.path)
    defer { restoreCodexHome(previousHome) }

    let counter = root.appendingPathComponent("launch-count")
    let executable = try makeQuotaExecutable(
      in: root,
      body: accountSwitchingRPCLoop(
        counterPath: counter.path,
        authPath: authURL.path
      )
    )
    let snapshot = try await CodexAppServerClient(
      executableURL: executable,
      timeout: 4
    ).fetchUsage()
    let expectedFingerprint = CredentialIdentity.fingerprint(
      canonicalCodexHome: URL(fileURLWithPath: home.path)
        .standardizedFileURL.resolvingSymlinksInPath().path,
      accountID: "second-account"
    )
    try check(
      readInteger(at: counter) == 2
        && snapshot.accountFingerprint == expectedFingerprint,
      "读取期间切账号会丢弃旧响应，并用新身份重新尝试"
    )
  }

  private static func checkUnverifiableQuotaIsDisplayOnly() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("codex-home", isDirectory: true)
    try FileManager.default.createDirectory(
      at: home,
      withIntermediateDirectories: true
    )
    try Data(#"{"auth_mode":"api_key","account_id":"ignored-account"}"#.utf8)
      .write(to: home.appendingPathComponent("auth.json"))
    let previousHome = try setCodexHome(home.path)
    defer { restoreCodexHome(previousHome) }

    let snapshot = try await CodexAppServerClient(
      executableURL: try makeQuotaExecutable(
        in: root,
        quotaReply: quotaReply(accountID: "server-account")
      ),
      timeout: 3
    ).fetchUsage()
    try check(
      snapshot.usedPercent == 12.5
        && snapshot.accountFingerprint == nil
        && snapshot.rateLimitsJSON == nil,
      "缺少可信 ChatGPT identity 时保留显示额度但不附加共享 metadata"
    )
  }

  private static func quotaReply(accountID: String) -> String {
    #"{"id":2,"result":{"accountId":"\#(accountID)","rateLimits":{"limitId":"codex","primary":{"usedPercent":12.5,"windowDurationMins":10080,"resetsAt":1893456000}}}}"#
  }

  private static func accountSwitchingRPCLoop(
    counterPath: String,
    authPath: String
  ) -> String {
    let counter = shellQuote(counterPath)
    let auth = shellQuote(authPath)
    return #"""
      count=0
      if [ -f \#(counter) ]; then IFS= read -r count < \#(counter) || count=0; fi
      count=$((count + 1))
      printf '%s\n' "$count" > \#(counter)
      while IFS= read -r line; do
        case "$line" in
          *'"method":"initialize"'*) printf '%s\n' '{"id":0,"result":{}}' ;;
          *'"method":"account/read"'*) printf '%s\n' '{"id":1,"result":{"account":{"type":"chatgpt","planType":"pro"},"requiresOpenaiAuth":true}}' ;;
          *'"method":"account/rateLimits/read"'*)
            if [ "$count" -eq 1 ]; then
              cat > \#(auth) <<'AUTH_JSON'
      {"auth_mode":"chatgpt","tokens":{"account_id":"second-account"}}
      AUTH_JSON
              printf '%s\n' '\#(quotaReply(accountID: "first-account"))'
            else
              printf '%s\n' '\#(quotaReply(accountID: "second-account"))'
            fi
            ;;
          *'"method":"account/usage/read"'*) printf '%s\n' '{"id":3,"result":{}}' ;;
        esac
      done
      """#
  }

  private static func makeQuotaExecutable(
    in directory: URL,
    quotaReply: String? = nil,
    body: String? = nil
  ) throws -> URL {
    let executable = directory.appendingPathComponent("codex-fake")
    let reply = quotaReply ?? self.quotaReply(accountID: "server-account")
    let rpcBody = body ?? #"""
      while IFS= read -r line; do
        case "$line" in
          *'"method":"initialize"'*) printf '%s\n' '{"id":0,"result":{}}' ;;
          *'"method":"account/read"'*) printf '%s\n' '{"id":1,"result":{"account":{"type":"chatgpt","planType":"pro"},"requiresOpenaiAuth":true}}' ;;
          *'"method":"account/rateLimits/read"'*) printf '%s\n' '\#(reply)' ;;
          *'"method":"account/usage/read"'*) printf '%s\n' '{"id":3,"result":{}}' ;;
        esac
      done
      """#
    try Data(("#!/bin/sh\nset -eu\n" + rpcBody + "\n").utf8)
      .write(to: executable)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: executable.path
    )
    return executable
  }

  private static func writeAuth(accountID: String, to url: URL) throws {
    let json = #"{"auth_mode":"chatgpt","tokens":{"account_id":"\#(accountID)"}}"#
    try Data(json.utf8).write(to: url)
  }

  private static func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("CodexSharedQuota-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    return directory
  }

  private static func setCodexHome(_ path: String) throws -> String? {
    let previous = ProcessInfo.processInfo.environment["CODEX_HOME"]
    guard setenv("CODEX_HOME", path, 1) == 0 else {
      throw SharedQuotaVerificationFailure("设置离线测试 CODEX_HOME 失败")
    }
    return previous
  }

  private static func restoreCodexHome(_ previous: String?) {
    if let previous {
      _ = setenv("CODEX_HOME", previous, 1)
    } else {
      _ = unsetenv("CODEX_HOME")
    }
  }

  private static func readInteger(at url: URL) -> Int? {
    guard let string = try? String(contentsOf: url, encoding: .utf8) else {
      return nil
    }
    return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  private static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  private static func check(
    _ value: Bool,
    _ message: String
  ) throws {
    guard value else {
      throw SharedQuotaVerificationFailure(message)
    }
    print("PASS \(message)")
  }
}

private struct SharedQuotaVerificationFailure: LocalizedError {
  let message: String

  init(_ message: String) {
    self.message = message
  }

  var errorDescription: String? { message }
}
