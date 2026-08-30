import CodexUsageCore
import CodexUsageShared
import Combine
import Foundation
import ServiceManagement
import WidgetKit

struct UsageHistoryPoint: Codable, Equatable, Identifiable, Sendable {
  let date: Date
  let usedPercent: Double

  var id: Date { date }
}

enum EPDProbePhase: Equatable {
  case idle
  case scanning
  case connecting(String)
  case reading(String)
  case ready
  case failed(String)

  var isBusy: Bool {
    switch self {
    case .scanning, .connecting, .reading: return true
    case .idle, .ready, .failed: return false
    }
  }
}

private enum EPDSyncTrigger {
  case manual
  case automatic
}

@MainActor
final class UsageViewModel: ObservableObject {
  @Published private(set) var snapshot: UsageSnapshot?
  @Published private(set) var isRefreshing = false
  @Published private(set) var errorMessage: String?
  @Published private(set) var lastUpdated: Date?
  @Published private(set) var launchAtLoginEnabled = false
  @Published private(set) var launchAtLoginErrorDetails: String?
  @Published private(set) var selectedSubscription: UsageSubscription
  @Published private(set) var displayLanguage: AppLanguage
  @Published private(set) var isLanguageSwitching = false
  @Published private(set) var usageHistory: [UsageHistoryPoint]
  @Published private(set) var epdProbePhase: EPDProbePhase = .idle
  @Published private(set) var epdInformation: NRFEPDDeviceInformation?
  @Published private(set) var isSendingEPDFrame = false
  @Published private(set) var epdSendMessage: String?
  @Published private(set) var lastEPDSyncAt: Date?

  private let client: CodexAppServerClient
  private let sharedUsageStore: SharedUsageStore
  private let sharedWidgetPreferencesStore: SharedWidgetPreferencesStore
  private let localUsageServer: LocalUsageSnapshotServer
  private let languageDefaults: UserDefaults
  private var epdTransport: NRFEPDBluetoothTransport?
  private var languageTransition: LanguageTransitionState
  private var activated = false
  private var refreshLoop: Task<Void, Never>?
  private var epdAutomaticSyncLoop: Task<Void, Never>?
  private var lastEPDCheckAt: Date?
  private var lastEPDFrameFingerprint: String?
  private static let refreshIntervalNanoseconds: UInt64 = 60_000_000_000
  private static let epdSchedulerTickNanoseconds: UInt64 = 60_000_000_000

  init(
    client: CodexAppServerClient = CodexAppServerClient(),
    sharedUsageStore: SharedUsageStore = SharedUsageStore(),
    sharedWidgetPreferencesStore: SharedWidgetPreferencesStore =
      SharedWidgetPreferencesStore(),
    localUsageServer: LocalUsageSnapshotServer = LocalUsageSnapshotServer(),
    displayLanguage: AppLanguage? = nil,
    languageDefaults: UserDefaults = .standard
  ) {
    self.client = client
    self.sharedUsageStore = sharedUsageStore
    self.sharedWidgetPreferencesStore = sharedWidgetPreferencesStore
    self.localUsageServer = localUsageServer
    self.languageDefaults = languageDefaults
    usageHistory = Self.loadUsageHistory(from: languageDefaults)
    let initialLanguage =
      displayLanguage
      ?? AppLanguage.resolve(
        languageDefaults.string(forKey: AppLanguage.storageKey)
      )
    self.displayLanguage = initialLanguage
    languageTransition = LanguageTransitionState(current: initialLanguage)
    selectedSubscription = UsageSubscription.resolve(
      sharedWidgetPreferencesStore.load()?.subscriptionID
    )
    restoreCachedSnapshot()
    restoreEPDState()
  }

  deinit {
    refreshLoop?.cancel()
    epdAutomaticSyncLoop?.cancel()
    localUsageServer.stop()
  }

  var menuBarText: String {
    if let snapshot {
      return "\(Int(snapshot.remainingPercent.rounded()))%"
    }
    return isRefreshing ? "…" : "--%"
  }

  /// The language that will be applied after the in-flight refresh finishes.
  /// The current display language remains unchanged until then.
  var pendingDisplayLanguage: AppLanguage? {
    languageTransition.pending
  }

  func selectSubscription(_ subscription: UsageSubscription) {
    guard subscription != selectedSubscription else {
      return
    }
    selectedSubscription = subscription
    snapshot = nil
    lastUpdated = nil
    errorMessage = nil
    restoreCachedSnapshot()
    persistWidgetPreferences()
    Task {
      await refresh()
    }
  }

  func planDisplayName(for language: AppLanguage) -> String {
    guard let plan = snapshot?.planType, !plan.isEmpty else {
      return language.text(.unknown)
    }
    if plan.lowercased() == "prolite" {
      return "Pro"
    }
    return plan.prefix(1).uppercased() + plan.dropFirst()
  }

  func resetDisplayText(for language: AppLanguage) -> String {
    language.resetDisplayText(snapshot?.resetsAt)
  }

  func lastUpdatedDisplayText(for language: AppLanguage) -> String {
    language.lastUpdatedDisplayText(lastUpdated)
  }

  func errorDisplayText(for language: AppLanguage) -> String? {
    errorMessage.map(language.localizedErrorMessage)
  }

  func launchAtLoginErrorText(for language: AppLanguage) -> String? {
    guard let launchAtLoginErrorDetails else {
      return nil
    }
    return
      "\(language.text(.launchAtLoginUpdateFailed)): "
      + launchAtLoginErrorDetails
  }

  func setDisplayLanguage(_ language: AppLanguage) {
    let result = languageTransition.request(
      language,
      whileRefreshing: isRefreshing
    )

    switch result {
    case .unchanged, .ignored:
      isLanguageSwitching = languageTransition.isWaitingForRefresh
    case .queued:
      isLanguageSwitching = true
    case .applied(let language):
      commitDisplayLanguage(language)
      isLanguageSwitching = false
    }
  }

  func activate() async {
    guard !activated else {
      return
    }
    activated = true
    localUsageServer.start()
    ensureLaunchAtLoginEnabled()
    await refresh()
    startRefreshLoop()
    startEPDAutomaticSyncLoop()
  }

  func refreshIfStale(maxAge: TimeInterval = 60) async {
    if let lastUpdated, Date().timeIntervalSince(lastUpdated) < maxAge {
      return
    }
    await refresh()
  }

  func refresh() async {
    guard !isRefreshing else {
      return
    }

    isRefreshing = true
    defer {
      isRefreshing = false
      applyPendingDisplayLanguageIfNeeded()
    }

    do {
      let fetchedSnapshot = try await client.fetchUsage()
      let updatedAt = Date()
      snapshot = fetchedSnapshot
      lastUpdated = updatedAt
      errorMessage = nil
      recordUsageHistory(
        usedPercent: fetchedSnapshot.usedPercent,
        at: updatedAt
      )
      if let pendingLanguage = takePendingDisplayLanguage() {
        updateDisplayLanguageState(pendingLanguage)
      }
      publishWidgetSnapshot(fetchedSnapshot, updatedAt: updatedAt)
    } catch {
      errorMessage =
        (error as? LocalizedError)?.errorDescription
        ?? error.localizedDescription
    }
  }

  func setLaunchAtLogin(_ enabled: Bool) {
    launchAtLoginErrorDetails = nil

    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
    } catch {
      launchAtLoginErrorDetails = error.localizedDescription
    }

    refreshLaunchAtLoginStatus()
  }

  func probeEPD() {
    guard !epdProbePhase.isBusy, !isSendingEPDFrame else { return }
    epdSendMessage = nil

    Task {
      let epdTransport = makeEPDTransport()
      do {
        epdProbePhase = .scanning
        let devices = try await epdTransport.scan()
        let device = try selectEPDDevice(from: devices)

        epdProbePhase = .connecting(device.name)
        try await epdTransport.connect(to: device)

        epdProbePhase = .reading(device.name)
        let information = try await epdTransport.waitForInformation()
        receiveEPDInformation(information)
        epdProbePhase = .ready
        epdSendMessage = "detected"
      } catch {
        let message =
          (error as? LocalizedError)?.errorDescription
          ?? error.localizedDescription
        epdProbePhase = .failed(message)
      }
      await epdTransport.disconnect()
    }
  }

  func disconnectEPD() {
    Task {
      await epdTransport?.disconnect()
      epdProbePhase = epdInformation == nil ? .idle : .ready
    }
  }

  func sendEPDLiveFrame() {
    Task {
      await synchronizeEPD(trigger: .manual)
    }
  }

  private func synchronizeEPD(trigger: EPDSyncTrigger) async {
    guard !isSendingEPDFrame, !epdProbePhase.isBusy else { return }

    let checkDate = Date()
    lastEPDCheckAt = checkDate
    languageDefaults.set(checkDate, forKey: Self.epdLastCheckAtStorageKey)
    isSendingEPDFrame = true
    epdSendMessage = nil
    defer { isSendingEPDFrame = false }

    do {
      try await refreshUsageForEPD()
      let content = try makeEPDLiveContent(now: Date())
      let fingerprint = try EPDSyncPolicy.contentFingerprint(content)
      if fingerprint == lastEPDFrameFingerprint {
        epdProbePhase = epdInformation == nil ? .idle : .ready
        epdSendMessage = "unchanged"
        return
      }

      let frame = try EPDLiveFrameRenderer.render(content)
      var finalError: Error?
      for attempt in 0..<2 {
        do {
          let epdTransport = makeEPDTransport()
          try await connectAndSendEPD(frame, using: epdTransport)
          await epdTransport.disconnect()

          let sentAt = Date()
          lastEPDFrameFingerprint = fingerprint
          lastEPDSyncAt = sentAt
          languageDefaults.set(
            fingerprint,
            forKey: Self.epdLastFrameFingerprintStorageKey
          )
          languageDefaults.set(sentAt, forKey: Self.epdLastSyncAtStorageKey)
          epdProbePhase = .ready
          epdSendMessage = trigger == .automatic ? "auto-success" : "success"
          return
        } catch {
          finalError = error
          await epdTransport?.disconnect()
          if attempt == 0 {
            try? await Task.sleep(nanoseconds: 500_000_000)
          }
        }
      }
      throw finalError ?? NRFEPDBluetoothError.notConnected
    } catch {
      let message =
        (error as? LocalizedError)?.errorDescription
        ?? error.localizedDescription
      epdProbePhase = .failed(message)
      epdSendMessage = message
    }
  }

  private func refreshUsageForEPD() async throws {
    if isRefreshing {
      while isRefreshing {
        try Task.checkCancellation()
        try await Task.sleep(nanoseconds: 100_000_000)
      }
    } else if lastUpdated.map({ Date().timeIntervalSince($0) >= 30 }) ?? true {
      await refresh()
    }

    if let errorMessage {
      throw EPDLiveFrameError.usageRefreshFailed(errorMessage)
    }
    guard snapshot != nil else {
      throw EPDLiveFrameError.missingUsageData
    }
  }

  private func connectAndSendEPD(
    _ frame: EPDFrame,
    using epdTransport: NRFEPDBluetoothTransport
  ) async throws {
    let device = try await connectToRememberedOrDiscoveredEPD(
      using: epdTransport
    )
    epdProbePhase = .reading(device.name)
    let information = try await epdTransport.waitForInformation()
    receiveEPDInformation(information)
    guard information.isStandardThreeColorDisplay else {
      throw NRFEPDBluetoothError.unsupportedDisplay(
        information.driverDescription
      )
    }
    try await epdTransport.send(frame: frame)
  }

  private func connectToRememberedOrDiscoveredEPD(
    using epdTransport: NRFEPDBluetoothTransport
  ) async throws -> EPDDeviceDescriptor {
    if let remembered = epdInformation?.device {
      do {
        epdProbePhase = .connecting(remembered.name)
        try await epdTransport.connect(to: remembered)
        return remembered
      } catch {
        await epdTransport.disconnect()
      }
    }

    epdProbePhase = .scanning
    let devices = try await epdTransport.scan()
    let device = try selectEPDDevice(from: devices)
    epdProbePhase = .connecting(device.name)
    try await epdTransport.connect(to: device)
    return device
  }

  func writeEPDDocumentationPreview(to path: String) throws {
    let content = try makeEPDLiveContent(now: lastUpdated ?? Date())
    try EPDLiveFrameRenderer.writePNG(
      content,
      to: URL(fileURLWithPath: path)
    )
  }

  private func makeEPDLiveContent(now: Date) throws -> EPDLiveContent {
    guard let snapshot else {
      throw EPDLiveFrameError.missingUsageData
    }
    let buckets = DailyTokenSeries.sevenDaysEnding(
      on: now,
      buckets: snapshot.tokenUsage?.dailyBuckets ?? [],
      timeZone: .current
    )
    return EPDLiveContent(
      now: now,
      updatedAt: lastUpdated ?? now,
      remainingPercent: snapshot.remainingPercent,
      resetsAt: snapshot.resetsAt,
      lifetimeTokens: snapshot.tokenUsage?.lifetimeTokens,
      dailyTokenUsage: buckets.map {
        SharedDailyTokenUsage(
          startDate: $0.startDate,
          tokens: $0.tokens
        )
      }
    )
  }

  private func makeEPDTransport() -> NRFEPDBluetoothTransport {
    if let epdTransport {
      return epdTransport
    }
    let transport = NRFEPDBluetoothTransport()
    transport.informationDidChange = { [weak self] information in
      self?.receiveEPDInformation(information)
    }
    epdTransport = transport
    return transport
  }

  private func receiveEPDInformation(_ information: NRFEPDDeviceInformation) {
    epdInformation = information
    languageDefaults.set(
      information.device.id,
      forKey: Self.epdDeviceIDStorageKey
    )
    languageDefaults.set(
      information.device.name,
      forKey: Self.epdDeviceNameStorageKey
    )
    if let firmwareVersion = information.firmwareVersion {
      languageDefaults.set(
        Int(firmwareVersion),
        forKey: Self.epdFirmwareStorageKey
      )
    } else {
      languageDefaults.removeObject(forKey: Self.epdFirmwareStorageKey)
    }
    if let driverID = information.driverID {
      languageDefaults.set(Int(driverID), forKey: Self.epdDriverStorageKey)
    } else {
      languageDefaults.removeObject(forKey: Self.epdDriverStorageKey)
    }
    if let pinConfiguration = information.pinConfiguration {
      languageDefaults.set(
        pinConfiguration,
        forKey: Self.epdPinConfigurationStorageKey
      )
    } else {
      languageDefaults.removeObject(
        forKey: Self.epdPinConfigurationStorageKey
      )
    }
    if let reportedMTU = information.reportedMTU {
      languageDefaults.set(reportedMTU, forKey: Self.epdMTUStorageKey)
    } else {
      languageDefaults.removeObject(forKey: Self.epdMTUStorageKey)
    }
    languageDefaults.set(
      information.supportsRLE,
      forKey: Self.epdRLEStorageKey
    )
  }

  private func restoreEPDState() {
    lastEPDCheckAt =
      languageDefaults.object(
        forKey: Self.epdLastCheckAtStorageKey
      ) as? Date
    lastEPDSyncAt =
      languageDefaults.object(
        forKey: Self.epdLastSyncAtStorageKey
      ) as? Date
    lastEPDFrameFingerprint = languageDefaults.string(
      forKey: Self.epdLastFrameFingerprintStorageKey
    )

    guard
      let id = languageDefaults.string(forKey: Self.epdDeviceIDStorageKey),
      let name = languageDefaults.string(forKey: Self.epdDeviceNameStorageKey)
    else { return }

    let firmware =
      (languageDefaults.object(
        forKey: Self.epdFirmwareStorageKey
      ) as? NSNumber)?.uint8Value
    let driver =
      (languageDefaults.object(
        forKey: Self.epdDriverStorageKey
      ) as? NSNumber)?.uint8Value
    let mtu =
      (languageDefaults.object(
        forKey: Self.epdMTUStorageKey
      ) as? NSNumber)?.intValue
    epdInformation = NRFEPDDeviceInformation(
      device: EPDDeviceDescriptor(id: id, name: name),
      firmwareVersion: firmware,
      driverID: driver,
      pinConfiguration: languageDefaults.data(
        forKey: Self.epdPinConfigurationStorageKey
      ),
      reportedMTU: mtu,
      supportsRLE: languageDefaults.bool(forKey: Self.epdRLEStorageKey)
    )
    epdProbePhase = .ready
  }

  private func selectEPDDevice(
    from devices: [EPDDeviceDescriptor]
  ) throws -> EPDDeviceDescriptor {
    guard !devices.isEmpty else {
      throw NRFEPDBluetoothError.noCompatibleDevice
    }

    let preferred = devices.filter {
      $0.name.uppercased().contains("8042")
    }
    if preferred.count == 1, let device = preferred.first {
      return device
    }
    if devices.count == 1, let device = devices.first {
      return device
    }
    throw NRFEPDBluetoothError.multipleCompatibleDevices(
      devices.map(\.name)
    )
  }

  private func restoreCachedSnapshot() {
    guard let cached = sharedUsageStore.load(),
      UsageSubscription.resolve(cached.subscriptionID) == selectedSubscription
    else {
      return
    }

    snapshot = UsageSnapshot(
      usedPercent: cached.usedPercent,
      windowDurationMinutes: cached.windowDurationMinutes
        ?? (selectedSubscription.usesWeeklyWindow ? 7 * 24 * 60 : 0),
      resetsAt: cached.resetsAt,
      planType: cached.planType,
      limitName: cached.limitName,
      reachedLimitType: nil,
      additionalWindows: (cached.additionalWindows ?? []).map {
        UsageWindow(
          id: $0.id,
          label: $0.label,
          usedPercent: $0.usedPercent,
          windowDurationMinutes: $0.windowDurationMinutes,
          resetsAt: $0.resetsAt
        )
      },
      tokenUsage: TokenUsage(
        lifetimeTokens: cached.lifetimeTokens,
        peakDailyTokens: nil,
        currentStreakDays: nil,
        dailyBuckets: (cached.dailyTokenUsage ?? []).map {
          DailyTokenUsage(startDate: $0.startDate, tokens: $0.tokens)
        }
      )
    )
    lastUpdated = cached.updatedAt
  }

  func loadDocumentationPreview(
    subscription: UsageSubscription = .codex
  ) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60) ?? .current
    let previewDate = Date()
    let previewValues: [Int64] = [
      420_000, 760_000, 510_000, 1_240_000, 900_000, 1_520_000, 680_000,
    ]
    let dateFormatter = DateFormatter()
    dateFormatter.calendar = calendar
    dateFormatter.locale = Locale(identifier: "en_US_POSIX")
    dateFormatter.timeZone = calendar.timeZone
    dateFormatter.dateFormat = "yyyy-MM-dd"
    let previewBuckets = zip(-6...0, previewValues).compactMap {
      offset, tokens -> DailyTokenUsage? in
      guard
        let day = calendar.date(
          byAdding: .day,
          value: offset,
          to: previewDate
        )
      else { return nil }
      return DailyTokenUsage(
        startDate: dateFormatter.string(from: day),
        tokens: tokens
      )
    }

    selectedSubscription = subscription
    snapshot = UsageSnapshot(
      usedPercent: 64,
      windowDurationMinutes: 10_080,
      resetsAt: calendar.date(byAdding: .day, value: 3, to: previewDate),
      planType: "pro",
      limitName: "Codex",
      reachedLimitType: nil,
      tokenUsage: TokenUsage(
        lifetimeTokens: 12_485_920,
        peakDailyTokens: 1_840_000,
        currentStreakDays: 8,
        dailyBuckets: previewBuckets
      )
    )
    lastUpdated = previewDate
    if let lastUpdated {
      usageHistory = [12, 19, 27, 31, 43, 52, 64].enumerated().map {
        index, percent in
        UsageHistoryPoint(
          date: lastUpdated.addingTimeInterval(
            Double(index - 6) * 24 * 60 * 60
          ),
          usedPercent: Double(percent)
        )
      }
    }
    errorMessage = nil
    isRefreshing = false
  }

  private func startRefreshLoop() {
    guard refreshLoop == nil else {
      return
    }

    refreshLoop = Task { [weak self] in
      let interval = Self.refreshIntervalNanoseconds
      var nextRefresh = DispatchTime.now().uptimeNanoseconds + interval

      while !Task.isCancelled {
        do {
          let now = DispatchTime.now().uptimeNanoseconds
          if now < nextRefresh {
            try await Task.sleep(nanoseconds: nextRefresh - now)
          }
        } catch {
          return
        }
        guard let self else {
          return
        }
        await self.refresh()

        nextRefresh += interval
        let now = DispatchTime.now().uptimeNanoseconds
        if nextRefresh <= now {
          nextRefresh = now + interval
        }
      }
    }
  }

  private func startEPDAutomaticSyncLoop() {
    guard epdAutomaticSyncLoop == nil else { return }

    epdAutomaticSyncLoop = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        let now = Date()
        if EPDSyncPolicy.automaticSyncIsDue(
          now: now,
          lastCheckAt: self.lastEPDCheckAt,
          timeZone: .current
        ) {
          await self.synchronizeEPD(trigger: .automatic)
        }

        do {
          try await Task.sleep(
            nanoseconds: Self.epdSchedulerTickNanoseconds
          )
        } catch {
          return
        }
      }
    }
  }

  private func recordUsageHistory(
    usedPercent: Double,
    at date: Date
  ) {
    let cutoff = date.addingTimeInterval(-7 * 24 * 60 * 60)
    usageHistory.removeAll { $0.date < cutoff }
    usageHistory.append(
      UsageHistoryPoint(
        date: date,
        usedPercent: min(100, max(0, usedPercent))
      )
    )

    if usageHistory.count > 10_080 {
      usageHistory.removeFirst(usageHistory.count - 10_080)
    }
    if let encoded = try? JSONEncoder().encode(usageHistory) {
      languageDefaults.set(encoded, forKey: Self.usageHistoryStorageKey)
    }
  }

  private static func loadUsageHistory(
    from defaults: UserDefaults
  ) -> [UsageHistoryPoint] {
    guard
      let data = defaults.data(forKey: usageHistoryStorageKey),
      let values = try? JSONDecoder().decode(
        [UsageHistoryPoint].self,
        from: data
      )
    else {
      return []
    }
    let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
    return values.filter { $0.date >= cutoff }.sorted { $0.date < $1.date }
  }

  private static let usageHistoryStorageKey = "codex-usage-history-v1"
  private static let epdDeviceIDStorageKey = "epd-device-id-v1"
  private static let epdDeviceNameStorageKey = "epd-device-name-v1"
  private static let epdFirmwareStorageKey = "epd-firmware-v1"
  private static let epdDriverStorageKey = "epd-driver-v1"
  private static let epdPinConfigurationStorageKey = "epd-pins-v1"
  private static let epdMTUStorageKey = "epd-mtu-v1"
  private static let epdRLEStorageKey = "epd-rle-v1"
  private static let epdLastCheckAtStorageKey = "epd-last-check-at-v1"
  private static let epdLastSyncAtStorageKey = "epd-last-sync-at-v1"
  private static let epdLastFrameFingerprintStorageKey =
    "epd-last-frame-fingerprint-v1"

  private func refreshLaunchAtLoginStatus() {
    launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
  }

  private func ensureLaunchAtLoginEnabled() {
    refreshLaunchAtLoginStatus()
    guard !launchAtLoginEnabled else {
      return
    }

    do {
      try SMAppService.mainApp.register()
      launchAtLoginErrorDetails = nil
    } catch {
      launchAtLoginErrorDetails = error.localizedDescription
    }
    refreshLaunchAtLoginStatus()
  }

  private func persistWidgetPreferences() {
    do {
      try sharedWidgetPreferencesStore.save(
        SharedWidgetPreferences(
          languageCode: displayLanguage.rawValue,
          subscriptionID: selectedSubscription.rawValue
        )
      )
    } catch {
      fputs("Widget preferences update failed: \(error)\n", stderr)
    }
  }

  private func applyPendingDisplayLanguageIfNeeded() {
    if let language = takePendingDisplayLanguage() {
      commitDisplayLanguage(language)
    }
  }

  private func takePendingDisplayLanguage() -> AppLanguage? {
    guard languageTransition.isWaitingForRefresh else {
      return nil
    }

    let result = languageTransition.finishRefreshing()
    isLanguageSwitching = languageTransition.isWaitingForRefresh
    if case .applied(let language) = result {
      return language
    }
    return nil
  }

  private func updateDisplayLanguageState(_ language: AppLanguage) {
    displayLanguage = language
    languageDefaults.set(language.rawValue, forKey: AppLanguage.storageKey)
    localUsageServer.updateLanguage(language.rawValue)
    persistWidgetPreferences()
  }

  private func commitDisplayLanguage(_ language: AppLanguage) {
    updateDisplayLanguageState(language)

    if let snapshot {
      publishWidgetSnapshot(
        snapshot,
        updatedAt: lastUpdated ?? Date()
      )
    } else {
      WidgetCenter.shared.reloadTimelines(
        ofKind: SharedUsageConfiguration.widgetKind
      )
    }
  }

  private func publishWidgetSnapshot(
    _ snapshot: UsageSnapshot,
    updatedAt: Date
  ) {
    let sharedSnapshot = SharedUsageSnapshot(
      usedPercent: snapshot.usedPercent,
      resetsAt: snapshot.resetsAt,
      planType: snapshot.planType,
      limitName: snapshot.limitName,
      updatedAt: updatedAt,
      windowDurationMinutes: snapshot.windowDurationMinutes,
      languageCode: displayLanguage.rawValue,
      subscriptionID: selectedSubscription.rawValue,
      additionalWindows: snapshot.additionalWindows.map {
        SharedUsageWindow(
          id: $0.id,
          label: $0.label,
          usedPercent: $0.usedPercent,
          windowDurationMinutes: $0.windowDurationMinutes,
          resetsAt: $0.resetsAt
        )
      },
      dailyTokenUsage: recentDailyTokenUsage(
        from: snapshot.tokenUsage?.dailyBuckets ?? [],
        relativeTo: updatedAt
      ),
      lifetimeTokens: snapshot.tokenUsage?.lifetimeTokens
    )

    localUsageServer.update(sharedSnapshot)
    do {
      try sharedUsageStore.save(sharedSnapshot)
    } catch {
      fputs("Widget snapshot update failed: \(error)\n", stderr)
    }
    WidgetCenter.shared.reloadTimelines(
      ofKind: SharedUsageConfiguration.widgetKind
    )
  }

  private func recentDailyTokenUsage(
    from buckets: [DailyTokenUsage],
    relativeTo date: Date
  ) -> [SharedDailyTokenUsage] {
    DailyTokenSeries.sevenDaysEnding(on: date, buckets: buckets).map { bucket in
      return SharedDailyTokenUsage(
        startDate: bucket.startDate,
        tokens: bucket.tokens
      )
    }
  }

}
