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
      try await verifyLocalSnapshotBridge()
      if CommandLine.arguments.contains("--integration") {
        try await runIntegrationCheck()
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
    try verifyEPDTransportBoundary()
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
    let snapshot = try await CodexAppServerClient().fetchUsage()
    try expect((0...100).contains(snapshot.usedPercent), "实时使用率范围")
    try expect(snapshot.windowDurationMinutes == 10_080, "实时周窗口长度")
    print(
      "PASS 实时 Codex 数据：已用 \(Int(snapshot.usedPercent.rounded()))%，"
        + "剩余 \(Int(snapshot.remainingPercent.rounded()))%"
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
    try verifyLanguageTransition()
  }

  private static func verifyEPDTransportBoundary() throws {
    let plane = Data(
      repeating: 0xFF,
      count: EPDFrame.standardPlaneByteCount
    )
    let frame = try EPDFrame(blackPlane: plane, redPlane: plane)
    try expect(
      frame.width == 400
        && frame.height == 300
        && frame.blackPlane.count == 15_000
        && frame.redPlane.count == 15_000,
      "保留 400×300 三色墨水屏帧接口"
    )

    do {
      _ = try EPDFrame(
        blackPlane: plane.dropLast(),
        redPlane: plane
      )
      throw VerificationFailure("拒绝错误长度的墨水屏图层")
    } catch EPDFrameValidationError.invalidPlaneByteCount {
      print("PASS 拒绝错误长度的墨水屏图层")
    }

    let samplePlane = Data((0..<40).map(UInt8.init))
    let modernPackets = try NRFEPDProtocol.imagePackets(
      plane: samplePlane,
      color: .black,
      maximumWriteValueLength: 20,
      usesModernHeader: true
    )
    try expect(
      modernPackets.count == 3
        && modernPackets[0].count == 20
        && modernPackets[0].prefix(2)
          == Data([NRFEPDProtocol.writeImageCommand, 0x02])
        && modernPackets[1].prefix(2)
          == Data([NRFEPDProtocol.writeImageCommand, 0x00]),
      "按 MTU 构建 NRF_EPD v1.6 黑色分包"
    )

    let legacyPackets = try NRFEPDProtocol.imagePackets(
      plane: samplePlane,
      color: .red,
      maximumWriteValueLength: 20,
      usesModernHeader: false
    )
    try expect(
      legacyPackets[0].prefix(2)
        == Data([NRFEPDProtocol.writeImageCommand, 0x00])
        && legacyPackets[1].prefix(2)
          == Data([NRFEPDProtocol.writeImageCommand, 0xF0]),
      "保留 NRF_EPD 旧固件红色分包兼容"
    )

    let legacyBlackPackets = try NRFEPDProtocol.imagePackets(
      plane: samplePlane,
      color: .black,
      maximumWriteValueLength: 20,
      usesModernHeader: false
    )
    try expect(
      legacyBlackPackets[0].prefix(2)
        == Data([NRFEPDProtocol.writeImageCommand, 0x0F])
        && legacyBlackPackets[1].prefix(2)
          == Data([NRFEPDProtocol.writeImageCommand, 0xFF]),
      "匹配说明书控制器的旧固件黑色分包"
    )

    try expect(
      !NRFEPDProtocol.shouldRequestWriteResponse(packetIndex: 49)
        && NRFEPDProtocol.shouldRequestWriteResponse(packetIndex: 50),
      "按卖家控制器策略每 51 个图像包请求一次确认"
    )

    let descriptor = EPDDeviceDescriptor(
      id: UUID().uuidString,
      name: "NRF_EPD_8042"
    )
    let information = NRFEPDDeviceInformation(
      device: descriptor,
      firmwareVersion: 0x16,
      driverID: 0x02,
      reportedMTU: 247,
      supportsRLE: true
    )
    try expect(
      information.isStandardThreeColorDisplay
        && information.driverDescription.contains("SSD1619"),
      "识别 NRF_EPD 4.2 英寸三色驱动"
    )

    let utc = TimeZone(secondsFromGMT: 0)!
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    let liveDate = calendar.date(
      from: DateComponents(year: 2026, month: 8, day: 30, hour: 17, minute: 8)
    )!
    let liveBuckets = zip(
      24...30,
      [420_000, 760_000, 510_000, 1_240_000, 900_000, 1_520_000, 680_000]
    ).map { day, tokens in
      SharedDailyTokenUsage(
        startDate: String(format: "2026-08-%02d", day),
        tokens: Int64(tokens)
      )
    }
    let liveContent = EPDLiveContent(
      now: liveDate,
      updatedAt: liveDate,
      remainingPercent: 90,
      resetsAt: calendar.date(
        from: DateComponents(year: 2026, month: 9, day: 1, hour: 8)
      ),
      lifetimeTokens: 32_800_000,
      dailyTokenUsage: liveBuckets,
      timeZone: utc
    )
    let liveFrame = try EPDLiveFrameRenderer.render(liveContent)
    let liveBlackPixelCount = liveFrame.blackPlane.reduce(0) {
      $0 + 8 - $1.nonzeroBitCount
    }
    let liveRedPixelCount = liveFrame.redPlane.reduce(0) {
      $0 + 8 - $1.nonzeroBitCount
    }
    try expect(
      liveBlackPixelCount > 1_000
        && liveRedPixelCount > 500
        && zip(liveFrame.blackPlane, liveFrame.redPlane).allSatisfy {
          black, red in ((~black) & (~red)) == 0
        },
      "把实时额度和 Token 数据渲染为互斥黑红位图"
    )
    let changedFrame = try EPDLiveFrameRenderer.render(
      EPDLiveContent(
        now: liveDate,
        updatedAt: liveDate,
        remainingPercent: 74,
        resetsAt: liveContent.resetsAt,
        lifetimeTokens: liveContent.lifetimeTokens,
        dailyTokenUsage: liveBuckets,
        timeZone: utc
      )
    )
    try expect(changedFrame != liveFrame, "实时额度变化会生成不同的墨水屏帧")

    let firstFingerprint = try EPDSyncPolicy.contentFingerprint(liveContent)
    let laterFooterTime = EPDLiveContent(
      now: liveContent.now,
      updatedAt: liveContent.updatedAt.addingTimeInterval(25 * 60),
      remainingPercent: liveContent.remainingPercent,
      resetsAt: liveContent.resetsAt,
      lifetimeTokens: liveContent.lifetimeTokens,
      dailyTokenUsage: liveContent.dailyTokenUsage,
      timeZone: liveContent.timeZone
    )
    let laterFooterFingerprint = try EPDSyncPolicy.contentFingerprint(
      laterFooterTime
    )
    try expect(
      laterFooterFingerprint == firstFingerprint,
      "墨水屏内容哈希忽略单独变化的更新时间"
    )
    let changedContentFingerprint = try EPDSyncPolicy.contentFingerprint(
      EPDLiveContent(
        now: liveContent.now,
        updatedAt: liveContent.updatedAt,
        remainingPercent: 74,
        resetsAt: liveContent.resetsAt,
        lifetimeTokens: liveContent.lifetimeTokens,
        dailyTokenUsage: liveContent.dailyTokenUsage,
        timeZone: liveContent.timeZone
      )
    )
    try expect(
      changedContentFingerprint != firstFingerprint,
      "墨水屏内容变化会生成新的稳定哈希"
    )
    try expect(
      !EPDSyncPolicy.automaticSyncIsDue(
        now: liveDate,
        lastCheckAt: liveDate.addingTimeInterval(-59 * 60),
        timeZone: utc
      )
        && EPDSyncPolicy.automaticSyncIsDue(
          now: liveDate,
          lastCheckAt: liveDate.addingTimeInterval(-60 * 60),
          timeZone: utc
        )
        && EPDSyncPolicy.automaticSyncIsDue(
          now: liveDate,
          lastCheckAt: calendar.date(
            byAdding: .day,
            value: -1,
            to: liveDate
          ),
          timeZone: utc
        ),
      "墨水屏每小时检查并在跨日后立即同步"
    )

    let previewURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("docs/images/epd-v1-preview.png")
    if FileManager.default.fileExists(atPath: previewURL.path) {
      let previewFrame = try EPDPreviewFrameLoader.load(from: previewURL)
      let blackPixelCount = previewFrame.blackPlane.reduce(0) {
        $0 + 8 - $1.nonzeroBitCount
      }
      let redPixelCount = previewFrame.redPlane.reduce(0) {
        $0 + 8 - $1.nonzeroBitCount
      }
      print(
        "INFO EPD preview pixels: black=\(blackPixelCount), red=\(redPixelCount)"
      )
      let planesDoNotOverlap = zip(
        previewFrame.blackPlane,
        previewFrame.redPlane
      ).allSatisfy { black, red in
        ((~black) & (~red)) == 0
      }
      try expect(
        blackPixelCount > 1_000
          && blackPixelCount < 40_000
          && redPixelCount > 500
          && redPixelCount < 20_000
          && previewFrame.blackPlane.contains(where: { $0 != 0xFF })
          && previewFrame.redPlane.contains(where: { $0 != 0xFF })
          && planesDoNotOverlap,
        "把批准的预览图转换为互斥黑红位图"
      )
      let flippedOrigin = EPDPreviewFrameLoader.verticallyFlippedSourceCoordinate(
        x: 0,
        y: 0,
        width: 400,
        height: 300
      )
      try expect(
        flippedOrigin.x == 0 && flippedOrigin.y == 299,
        "按实体屏安装方向仅纵向翻转画面"
      )
    }
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
