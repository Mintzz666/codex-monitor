import CodexUsageCore
import CodexUsageShared
import Darwin
import Foundation

@main
struct CodexUsageVerifier {
  static func main() async {
    do {
      try runUnitChecks()
      try await verifyAppServerCompatibility()
      try await SharedQuotaChecks.run()
      try await NetworkChecks.run()
      try await verifyLocalSnapshotBridge()
      if CommandLine.arguments.contains("--integration") {
        try await runIntegrationCheck()
      }
      if CommandLine.arguments.contains("--radar-integration") {
        try await ResetRadarChecks.integration()
      }
      print("验证完成：全部通过")
    } catch {
      fputs("验证失败：\(error.localizedDescription)\n", stderr)
      exit(1)
    }
  }

  private static func runUnitChecks() throws {
    let primaryWeekly = try decodeRateLimits(
      """
      {
        "rateLimits": {
          "limitId": "codex",
          "limitName": "Codex",
          "planType": "pro",
          "primary": {
            "usedPercent": 33,
            "windowDurationMins": 10080,
            "resetsAt": 1785645051
          },
          "secondary": null,
          "rateLimitReachedType": null
        },
        "rateLimitsByLimitId": {}
      }
      """
    )
    let primaryUsage = try WeeklyUsageSelector.select(
      from: primaryWeekly,
      accountPlanType: nil
    )
    try expect(primaryUsage.usedPercent == 33, "选择 primary 周窗口")
    try expect(primaryUsage.remainingPercent == 67, "计算剩余额度")
    try expect(primaryUsage.windowDurationMinutes == 10_080, "保留周窗口长度")
    try expect(primaryUsage.planType == "pro", "读取套餐")
    try expect(primaryUsage.limitName == "Codex", "读取限额名称")
    try expect(
      primaryUsage.resetsAt == Date(timeIntervalSince1970: 1_785_645_051),
      "解析重置时间"
    )

    let secondaryWeekly = try decodeRateLimits(
      """
      {
        "rateLimits": {
          "limitId": "codex",
          "primary": {
            "usedPercent": 5,
            "windowDurationMins": 300,
            "resetsAt": 1000
          },
          "secondary": {
            "usedPercent": 61.5,
            "windowDurationMins": 10080,
            "resetsAt": 2000
          }
        }
      }
      """
    )
    let secondaryUsage = try WeeklyUsageSelector.select(
      from: secondaryWeekly,
      accountPlanType: "plus"
    )
    try expect(secondaryUsage.usedPercent == 61.5, "从 secondary 选择周窗口")
    try expect(secondaryUsage.planType == "plus", "优先使用账号套餐")
    try expect(
      secondaryUsage.additionalWindows.first?.windowDurationMinutes == 300,
      "把非周额度作为动态附加窗口"
    )

    let mappedWeekly = try decodeRateLimits(
      """
      {
        "rateLimits": null,
        "rateLimitsByLimitId": {
          "codex": {
            "limitId": "codex",
            "primary": {
              "usedPercent": 42,
              "windowDurationMins": 10080,
              "resetsAt": 3000
            }
          }
        }
      }
      """
    )
    let mappedUsage = try WeeklyUsageSelector.select(
      from: mappedWeekly,
      accountPlanType: "business"
    )
    try expect(mappedUsage.usedPercent == 42, "从 rateLimitsByLimitId 兜底")
    try expect(mappedUsage.limitName == "codex", "保留 limit ID")

    let clampedWeekly = try decodeRateLimits(
      """
      {
        "rateLimits": {
          "primary": {
            "usedPercent": 120,
            "windowDurationMins": 10080
          }
        }
      }
      """
    )
    let clampedUsage = try WeeklyUsageSelector.select(
      from: clampedWeekly,
      accountPlanType: nil
    )
    try expect(clampedUsage.usedPercent == 100, "限制异常百分比范围")

    let shortWindow = try decodeRateLimits(
      """
      {
        "rateLimits": {
          "primary": {
            "usedPercent": 10,
            "windowDurationMins": 300
          }
        }
      }
      """
    )
    do {
      _ = try WeeklyUsageSelector.select(from: shortWindow, accountPlanType: nil)
      throw VerificationFailure("拒绝把短周期误认为周限额")
    } catch UsageSelectionError.noWeeklyWindow {
      print("PASS 拒绝把短周期误认为周限额")
    }

    try verifyExecutableOverride()
    try verifySharedUsageStore()
    try verifyAppLanguage()
    try verifyDailyTokenSeries()
    try ResetRadarChecks.run()
  }

  private static func verifyDailyTokenSeries() throws {
    let utc = TimeZone(secondsFromGMT: 0)!
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    let today = calendar.date(
      from: DateComponents(year: 2026, month: 8, day: 30, hour: 12)
    )!
    let series = DailyTokenSeries.sevenDaysEnding(
      on: today,
      buckets: [
        DailyTokenUsage(startDate: "2026-08-28", tokens: 120),
        DailyTokenUsage(startDate: "2026-08-29", tokens: 200),
        DailyTokenUsage(startDate: "2026-08-29", tokens: 30),
      ],
      timeZone: utc
    )

    try expect(
      series.count == 7
        && series.first?.startDate == "2026-08-24"
        && series.last?.startDate == "2026-08-30",
      "菜单 Token 折线固定以今天结束"
    )
    try expect(
      series[4].tokens == 120
        && series[5].tokens == 230
        && series[6].tokens == 0,
      "菜单 Token 折线补齐缺失日期并合并重复桶"
    )
  }

  private static func runIntegrationCheck() async throws {
    let started = ProcessInfo.processInfo.systemUptime
    let snapshot = try await CodexAppServerClient().fetchUsage()
    let currentFingerprint = CredentialIdentity.currentFingerprint()
    try expect(
      currentFingerprint != nil
        && snapshot.accountFingerprint == currentFingerprint,
      "实时共享 quota metadata 与当前 credential 指纹一致"
    )

    let quotaObject = snapshot.rateLimitsJSON.flatMap { json in
      try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    } ?? [:]
    let rateLimitEntries: [(String, [String: Any])] = {
      var entries: [(String, [String: Any])] = []
      if let defaultLimit = quotaObject["rateLimits"] as? [String: Any] {
        entries.append((defaultLimit["limitId"] as? String ?? "", defaultLimit))
      }
      if let mappedLimits = quotaObject["rateLimitsByLimitId"] as? [String: Any] {
        for (key, value) in mappedLimits {
          if let limit = value as? [String: Any] {
            entries.append((limit["limitId"] as? String ?? key, limit))
          }
        }
      }
      return entries
    }()
    let hasCodexWeeklyWindow = rateLimitEntries.contains { limitID, limit in
      guard limitID == "codex" else { return false }
      return ["primary", "secondary"].contains { key in
        guard let window = limit[key] as? [String: Any],
          window["usedPercent"] as? Double != nil
        else {
          return false
        }
        let duration = window["windowDurationMins"] as? Int
          ?? (window["windowDurationSeconds"] as? Int).map { ($0 + 59) / 60 }
        return duration.map { (8_640...11_520).contains($0) } ?? false
      }
    }
    try expect(
      quotaObject["accountId"] == nil
        && quotaObject["account_id"] == nil
        && hasCodexWeeklyWindow,
      "实时 rateLimitsJSON 可解析、已脱敏且包含 Codex 周窗口"
    )

    let hasTokenUsage = snapshot.tokenUsage.map {
      $0.lifetimeTokens != nil || !$0.dailyBuckets.isEmpty
    } ?? false
    try expect((0...100).contains(snapshot.usedPercent), "实时使用率范围")
    try expect(snapshot.windowDurationMinutes == 10_080, "实时周窗口长度")
    print(
      "PASS 实时 Codex 数据：已用 \(Int(snapshot.usedPercent.rounded()))%，"
        + "剩余 \(Int(snapshot.remainingPercent.rounded()))%，"
        + String(format: "耗时 %.2f 秒", ProcessInfo.processInfo.systemUptime - started)
        + "，Token 数据\(hasTokenUsage ? "已读取" : "暂不可用")"
    )
  }

  private static func verifyAppServerCompatibility() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: true
    )
    defer {
      try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    let executable = temporaryDirectory.appendingPathComponent("codex")
    let script = """
      #!/bin/sh
      if [ "$2" = "--stdio" ]; then
        exit 64
      fi
      while IFS= read -r line; do
        case "$line" in
          *initialize*)
            printf '%s\\n' '{"id":0,"result":{}}'
            ;;
          *account/read*)
            printf '%s\\n' '{"id":1,"result":{"account":{"type":"chatgpt","planType":"pro"},"requiresOpenaiAuth":true}}'
            ;;
          *account/rateLimits/read*)
            printf '%s\\n' '{"id":2,"result":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":"12.5","window_duration_seconds":604800,"resets_at":1788138263}}}}'
            ;;
          *account/usage/read*)
            printf '%s\\n' '{"id":3,"result":{"summary":{"lifetimeTokens":123456},"dailyUsageBuckets":[{"startDate":"2026-08-27","tokens":12000}]}}'
            ;;
        esac
      done
      """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: executable.path
    )

    let snapshot = try await CodexAppServerClient(
      executableURL: executable,
      timeout: 2
    ).fetchUsage()
    try expect(
      snapshot.usedPercent == 12.5
        && snapshot.windowDurationMinutes == 10_080
        && snapshot.planType == "pro",
      "兼容 CLI 参数回退、顺序握手、snake_case 和秒级窗口字段"
    )
    try expect(
      snapshot.tokenUsage?.lifetimeTokens == 123_456
        && snapshot.tokenUsage?.dailyBuckets.first?.tokens == 12_000,
      "读取官方 token 汇总与每日桶"
    )
  }

  private static func verifyExecutableOverride() throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: true
    )
    defer {
      try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    let executable = temporaryDirectory.appendingPathComponent("codex")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: executable.path
    )

    let resolved = try CodexExecutableLocator.resolve(
      environment: [
        "CODEX_BINARY_PATH": executable.path,
        "PATH": "",
      ],
      homeDirectory: temporaryDirectory.path
    )
    try expect(resolved.path == executable.path, "优先使用 CODEX_BINARY_PATH")
  }

  private static func verifySharedUsageStore() throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer {
      try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    let updatedAt = Date(timeIntervalSince1970: 1_785_645_051)
    let snapshot = SharedUsageSnapshot(
      usedPercent: 120,
      resetsAt: updatedAt.addingTimeInterval(3_600),
      planType: "pro",
      limitName: "Codex",
      updatedAt: updatedAt,
      languageCode: AppLanguage.english.rawValue
    )
    try expect(snapshot.usedPercent == 100, "共享快照限制使用率范围")
    try expect(snapshot.remainingPercent == 0, "共享快照计算剩余额度")
    try expect(
      snapshot.isStale(
        relativeTo: updatedAt.addingTimeInterval(901)
      ),
      "共享快照识别过期数据"
    )

    let store = SharedUsageStore(directoryURL: temporaryDirectory)
    try store.save(snapshot)
    try expect(store.load() == snapshot, "共享快照原子写入与读取")
    try expect(
      store.load()?.languageCode == AppLanguage.english.rawValue,
      "共享快照保留 Widget 语言"
    )
    try store.clear()
    try expect(store.load() == nil, "切换账号时可清除 app-group quota 缓存")

    let preferencesStore = SharedWidgetPreferencesStore(
      directoryURL: temporaryDirectory
    )
    let preferences = SharedWidgetPreferences(
      languageCode: AppLanguage.english.rawValue
    )
    try preferencesStore.save(preferences)
    try expect(
      preferencesStore.load() == preferences,
      "独立持久化 Widget 语言设置"
    )

    let legacyPreferences = try JSONDecoder().decode(
      SharedWidgetPreferences.self,
      from: Data("{\"languageCode\":\"en\"}".utf8)
    )
    try expect(
      legacyPreferences.subscriptionID == nil,
      "兼容不含订阅字段的旧偏好"
    )

    let legacySnapshotData = try JSONSerialization.data(
      withJSONObject: [
        "usedPercent": 25,
        "updatedAt": updatedAt.timeIntervalSinceReferenceDate,
      ]
    )
    let legacySnapshot = try JSONDecoder().decode(
      SharedUsageSnapshot.self,
      from: legacySnapshotData
    )
    try expect(
      legacySnapshot.languageCode == nil,
      "兼容不含语言字段的旧 Widget 快照"
    )
    try expect(
      legacySnapshot.windowDurationMinutes == nil,
      "兼容不含窗口时长字段的旧 Widget 快照"
    )
  }

  private static func verifyAppLanguage() throws {
    let defaultsSuite = "CodexUsageVerifier.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: defaultsSuite) else {
      throw VerificationFailure("创建语言偏好测试存储")
    }
    defer {
      defaults.removePersistentDomain(forName: defaultsSuite)
    }
    defaults.set(AppLanguage.english.rawValue, forKey: AppLanguage.storageKey)

    try expect(
      AppLanguage.resolve("zh-Hans") == .simplifiedChinese,
      "恢复已保存的中文选择"
    )
    try expect(
      AppLanguage.resolve("en") == .english,
      "恢复已保存的英文选择"
    )
    try expect(
      AppLanguage.resolve(
        defaults.string(forKey: AppLanguage.storageKey)
      ) == .english,
      "持久化用户语言选择"
    )
    try expect(
      AppLanguage.simplifiedChinese.toggled == .english
        && AppLanguage.english.toggled == .simplifiedChinese,
      "中英文切换可逆"
    )
    try expect(
      AppLanguage.simplifiedChinese.text(.weeklyUsed) == "本周已用"
        && AppLanguage.english.text(.weeklyUsed) == "Used this week",
      "提供中英文界面文案"
    )
    try expect(
      AppLanguage.english.localizedErrorMessage("读取 Codex 限额超时")
        == "Timed out while reading the Codex limit",
      "切换英文错误提示"
    )
    try expect(
      AppLanguage.english.widgetWaitingTitle == "Waiting for usage data"
        && AppLanguage.simplifiedChinese.widgetWaitingTitle == "等待用量数据",
      "提供中英文 Widget 文案"
    )
    try expect(
      AppLanguage.simplifiedChinese.text(.checkForUpdates) == "检查更新"
        && AppLanguage.english.text(.checkForUpdates) == "Check for updates",
      "提供中英文更新按钮文案"
    )
    try expect(
      AppLanguage.simplifiedChinese.text(.updateAvailable) == "新版本"
        && AppLanguage.english.text(.updateAvailable) == "New version",
      "提供中英文新版本提示"
    )
    try expect(
      AppLanguage.simplifiedChinese.text(.switchingLanguage) == "正在切换"
        && AppLanguage.english.text(.switchingLanguage) == "Switching",
      "提供中英文切换状态文案"
    )
    try expect(
      AppLanguage.simplifiedChinese.tokenDateLabel("2026-10-21") == "10/21"
        && AppLanguage.simplifiedChinese.tokenWeekdayLabel("2026-10-21") == "周三"
        && AppLanguage.english.tokenWeekdayLabel("2026-10-21") == "Wed",
      "图表显示同一日的日期和中英文星期"
    )
    try expect(
      AppLanguage.english.tokenDateLabel("2027-01-01") == "1/1"
        && AppLanguage.english.tokenWeekdayLabel("2027-01-01") == "Fri"
        && AppLanguage.english.tokenWeekdayLabel("2028-02-29") == "Tue",
      "图表日期跨年和闰日保持正确星期"
    )
    try expect(
      AppLanguage.english.tokenDateLabel("2026-02-30") == "2026-02-30",
      "拒绝将无效日期静默归到下一月"
    )
    try verifyLanguageTransition()
  }

  private static func verifyLanguageTransition() throws {
    var transition = LanguageTransitionState(current: .simplifiedChinese)

    try expect(
      transition.request(.english, whileRefreshing: true) == .queued,
      "刷新期间暂存语言切换"
    )
    try expect(
      transition.current == .simplifiedChinese
        && transition.pending == .english
        && transition.isWaitingForRefresh,
      "暂存期间保持当前界面语言"
    )
    try expect(
      transition.finishRefreshing() == .applied(.english)
        && transition.current == .english
        && !transition.isWaitingForRefresh,
      "刷新完成后应用待切换语言"
    )
    try expect(
      transition.request(.simplifiedChinese, whileRefreshing: false)
        == .applied(.simplifiedChinese),
      "空闲状态立即应用语言切换"
    )
    try expect(
      transition.request(.english, whileRefreshing: true) == .queued
        && transition.request(.simplifiedChinese, whileRefreshing: true)
          == .ignored
        && transition.pending == .english
        && transition.isWaitingForRefresh,
      "切换期间忽略快速重复点击"
    )
    try expect(
      transition.finishRefreshing() == .applied(.english)
        && transition.current == .english
        && transition.pending == nil
        && !transition.isWaitingForRefresh,
      "快速点击后仍应用已确认语言"
    )
  }

  private static func verifyLocalSnapshotBridge() async throws {
    let basePort = UInt16.random(in: 54_000...59_000)
    let ports = [basePort, basePort + 1, basePort + 2]
    let updatedAt = Date(timeIntervalSince1970: 1_785_645_051)
    let expected = SharedUsageSnapshot(
      usedPercent: 47,
      resetsAt: updatedAt.addingTimeInterval(3_600),
      planType: "pro",
      limitName: "Codex",
      updatedAt: updatedAt,
      languageCode: AppLanguage.english.rawValue
    )
    let server = LocalUsageSnapshotServer(ports: ports)
    server.update(expected)
    server.start()
    defer {
      server.stop()
    }

    try await Task.sleep(nanoseconds: 300_000_000)
    let client = LocalUsageSnapshotClient(ports: ports, timeout: 1.5)
    let received = await withCheckedContinuation { continuation in
      client.load { snapshot in
        continuation.resume(returning: snapshot)
      }
    }
    try expect(received == expected, "本机回环同步 Widget 快照")

    server.invalidateSnapshot()
    let invalidatedPayload = await withCheckedContinuation { continuation in
      client.loadPayload { payload in
        continuation.resume(returning: payload)
      }
    }
    try expect(
      invalidatedPayload?.snapshot == nil
        && invalidatedPayload?.languageCode == AppLanguage.english.rawValue,
      "账号切换后 loopback 不再返回旧额度并保留语言设置"
    )

    let languagePorts = [basePort + 10, basePort + 11, basePort + 12]
    let languageServer = LocalUsageSnapshotServer(ports: languagePorts)
    languageServer.updateLanguage(AppLanguage.simplifiedChinese.rawValue)
    languageServer.start()
    defer {
      languageServer.stop()
    }

    try await Task.sleep(nanoseconds: 300_000_000)
    let languageClient = LocalUsageSnapshotClient(
      ports: languagePorts,
      timeout: 1.5
    )
    let languagePayload = await withCheckedContinuation { continuation in
      languageClient.loadPayload { payload in
        continuation.resume(returning: payload)
      }
    }
    try expect(
      languagePayload?.snapshot == nil
        && languagePayload?.languageCode
          == AppLanguage.simplifiedChinese.rawValue,
      "无用量快照时同步 Widget 语言设置"
    )
  }

  private static func decodeRateLimits(_ json: String) throws -> RateLimitsReadResult {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(
      RateLimitsReadResult.self,
      from: Data(json.utf8)
    )
  }

  private static func expect(
    _ condition: @autoclosure () -> Bool,
    _ name: String
  ) throws {
    guard condition() else {
      throw VerificationFailure(name)
    }
    print("PASS \(name)")
  }
}

private struct VerificationFailure: LocalizedError {
  let name: String

  init(_ name: String) {
    self.name = name
  }

  var errorDescription: String? {
    "检查未通过：\(name)"
  }
}

enum ResetRadarChecks {
  static func run() throws {
    let now = ISO8601DateFormatter().date(from: "2026-10-21T08:00:00Z")!
    let valid: [String: Any] = [
      "id": "2111492738025959922", "type": "reset", "group": "reset",
      "scope": "global", "confirmed": true, "preview": false,
      "banked_grant": false, "reset_kind": "hard", "announcement_state": "announced",
      "announced_at": "2026-10-17T20:41:01.000Z",
      "url": "https://x.com/thsottiaux/status/2111492738025959922",
    ]
    var records = [valid, valid]
    for changes: [String: Any] in [
      ["confirmed": false], ["confirmed": NSNull()], ["preview": true],
      ["banked_grant": true], ["reset_kind": "banked"], ["group": "credits"],
      ["scope": "personal"], ["announcement_state": "pending"],
      ["url": "https://x.com.evil.invalid/thsottiaux/status/2111492738025959922"],
      ["url": "https://x.com/another_author/status/2111492738025959922"],
      ["announced_at": "2026-10-22T00:00:00Z"],
    ] {
      records.append(valid.merging(changes) { _, new in new })
    }
    // Put invalid rows first so an implementation cannot pass by de-duplicating
    // them before checking whether each record is a real global confirmation.
    records = Array(records.dropFirst(2)) + [valid, valid]
    let timelineData = try JSONSerialization.data(withJSONObject: [
      "updated_at": "2026-10-21T07:59:00Z", "events": records,
    ])
    let timeline = try ResetRadarParser.parseTimeline(timelineData, now: now)
    try check(timeline.events.count == 1, "RESET 仅保留确认的全局重置，过滤 BANKED、预告、伪来源并去重")
    let event = timeline.events[0]
    try check(
      event.dateKey(timeZone: TimeZone(secondsFromGMT: 8 * 3_600)!) == "2026-10-18"
        && event.dateKey(timeZone: TimeZone(secondsFromGMT: 0)!) == "2026-10-17",
      "RESET 按本机时区归日，避免把 UTC 17 日错误标到北京时间 17 日"
    )

    func forecast(_ first: Double, _ second: Double, at: String = "2026-10-21T07:59:00.000Z") throws -> Data {
      try JSONSerialization.data(withJSONObject: [
        "updated_at": at, "confidence": "low",
        "probabilities": ["rounded_24h": first, "rounded_48h": second],
      ])
    }
    let fresh = try ResetRadarParser.parseForecast(forecast(22, 39), now: now)
    try check(fresh.percent24h == 22 && fresh.percent48h == 39 && fresh.isFresh(at: now), "展示源站 24h/48h 数值和源更新时间")
    let stale = try ResetRadarParser.parseForecast(forecast(22, 39, at: "2026-10-21T07:00:00Z"), now: now)
    try check(!stale.isFresh(at: now), "超过 30 分钟的预测不能作为当前预测")
    for data in [try forecast(101, 110), try forecast(60, 20), try forecast(22, 39, at: "2026-10-21T09:00:00Z")] {
      do {
        _ = try ResetRadarParser.parseForecast(data, now: now)
        throw NSError(domain: "ResetRadarChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "接受了无效预测"])
      } catch ResetRadarError.invalidResponse {
        // Expected: malformed/future probabilities do not replace the cache.
      }
    }
    print("PASS 拒绝越界、非单调和异常未来时间的预测")
  }

  static func integration() async throws {
    let snapshot = try await ResetRadarClient().fetch()
    try check(snapshot.forecast.isFresh(), "实时社区预测来源新鲜")
    try check(!snapshot.events.isEmpty, "实时读取已确认历史并保留原帖链接")
    print("PASS Reset source: 24h=\(snapshot.forecast.percent24h)%, 48h=\(snapshot.forecast.percent48h)%; dates=\(snapshot.events.prefix(3).map { $0.dateKey() })")
  }

  private static func check(_ value: Bool, _ message: String) throws {
    guard value else {
      throw NSError(domain: "ResetRadarChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    print("PASS \(message)")
  }
}
