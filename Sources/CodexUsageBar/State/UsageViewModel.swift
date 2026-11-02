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
  @Published private(set) var resetRadar: ResetRadarSnapshot?
  @Published private(set) var resetRadarError: String?

  private let client: CodexAppServerClient
  private let resetRadarClient = ResetRadarClient()
  private let sharedUsageStore: SharedUsageStore
  private let sharedWidgetPreferencesStore: SharedWidgetPreferencesStore
  private let localUsageServer: LocalUsageSnapshotServer
  private let languageDefaults: UserDefaults
  private var languageTransition: LanguageTransitionState
  private var activated = false
  private var refreshLoop: Task<Void, Never>?
  private var isResetRadarRefreshing = false
  private var lastResetRadarAttempt: Date?
  private var consecutiveRefreshFailures = 0
  private var observedAccountFingerprint = CredentialIdentity.currentFingerprint()
  private static let resetRadarStorageKey = "codex-reset-radar-v1"

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
    if let data = languageDefaults.data(forKey: Self.resetRadarStorageKey) {
      resetRadar = try? JSONDecoder().decode(ResetRadarSnapshot.self, from: data)
    }
  }

  deinit {
    refreshLoop?.cancel()
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
    if let snapshot, let lastUpdated {
      publishWidgetSnapshot(snapshot, updatedAt: lastUpdated)
    }
    ensureLaunchAtLoginEnabled()
    await refresh()
    startRefreshLoop()
  }

  func refreshIfStale(maxAge: TimeInterval = 60) async {
    let accountChanged = invalidateForAccountChangeIfNeeded()
    if !accountChanged, let lastUpdated,
      Date().timeIntervalSince(lastUpdated) < maxAge
    {
      await refreshResetRadarIfStale()
      return
    }
    await refresh()
  }

  func refresh(forceRadar: Bool = false) async {
    _ = invalidateForAccountChangeIfNeeded()
    guard !isRefreshing else {
      return
    }

    isRefreshing = true
    async let radarRefresh: Void = refreshResetRadarIfStale(force: forceRadar)
    defer {
      isRefreshing = false
      applyPendingDisplayLanguageIfNeeded()
    }

    do {
      let fetchedSnapshot = try await client.fetchUsage()
      let fetchedFingerprint = CredentialIdentity.currentFingerprint()
      if let snapshotFingerprint = fetchedSnapshot.accountFingerprint,
        snapshotFingerprint != fetchedFingerprint
      {
        throw CredentialIdentityError.accountChanged
      }
      observedAccountFingerprint = fetchedFingerprint
      let updatedAt = Date()
      snapshot = fetchedSnapshot
      lastUpdated = updatedAt
      errorMessage = nil
      consecutiveRefreshFailures = 0
      recordUsageHistory(
        usedPercent: fetchedSnapshot.usedPercent,
        at: updatedAt
      )
      if let pendingLanguage = takePendingDisplayLanguage() {
        updateDisplayLanguageState(pendingLanguage)
      }
      publishWidgetSnapshot(fetchedSnapshot, updatedAt: updatedAt)
    } catch {
      consecutiveRefreshFailures = min(consecutiveRefreshFailures + 1, 3)
      if !invalidateForAccountChangeIfNeeded() {
        errorMessage =
          (error as? LocalizedError)?.errorDescription
          ?? error.localizedDescription
      }
    }
    await radarRefresh
  }

  func refreshResetRadarIfStale(force: Bool = false) async {
    guard !isResetRadarRefreshing else { return }
    if !force, let lastResetRadarAttempt,
      Date().timeIntervalSince(lastResetRadarAttempt) < 300
    { return }
    isResetRadarRefreshing = true
    lastResetRadarAttempt = Date()
    defer { isResetRadarRefreshing = false }
    do {
      let radar = try await resetRadarClient.fetch()
      resetRadar = radar
      resetRadarError = nil
      if let data = try? JSONEncoder().encode(radar) {
        languageDefaults.set(data, forKey: Self.resetRadarStorageKey)
      }
    } catch {
      // Keep historical evidence. The UI hides forecast percentages when the
      // source cannot be checked, independently of the account's usage refresh.
      resetRadarError = error.localizedDescription
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
      languageDefaults.set(true, forKey: Self.launchAtLoginConfiguredKey)
    } catch {
      launchAtLoginErrorDetails = error.localizedDescription
    }

    refreshLaunchAtLoginStatus()
  }

  private func restoreCachedSnapshot() {
    guard let cached = sharedUsageStore.load(),
      UsageSubscription.resolve(cached.subscriptionID) == selectedSubscription
    else {
      return
    }
    guard let currentFingerprint = CredentialIdentity.currentFingerprint(),
      cached.accountFingerprint == currentFingerprint
    else {
      clearSharedQuotaCaches()
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
      ),
      accountFingerprint: cached.accountFingerprint,
      rateLimitsJSON: cached.rateLimitsJSON
    )
    lastUpdated = cached.updatedAt
  }

  @discardableResult
  private func invalidateForAccountChangeIfNeeded() -> Bool {
    let currentFingerprint = CredentialIdentity.currentFingerprint()
    guard currentFingerprint != observedAccountFingerprint else {
      return false
    }

    observedAccountFingerprint = currentFingerprint
    snapshot = nil
    lastUpdated = nil
    errorMessage = nil
    clearSharedQuotaCaches()
    return true
  }

  private func clearSharedQuotaCaches() {
    do {
      try sharedUsageStore.clear()
    } catch {
      fputs("Shared quota cache invalidation failed\n", stderr)
    }
    localUsageServer.invalidateSnapshot()
    WidgetCenter.shared.reloadTimelines(
      ofKind: SharedUsageConfiguration.widgetKind
    )
  }

  func loadDocumentationPreview(
    subscription: UsageSubscription = .codex
  ) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
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
      while !Task.isCancelled {
        guard let failures = self?.consecutiveRefreshFailures else { return }
        // Recover promptly from a dropped route, then back off during a
        // longer outage. Successful polls retain the normal minute cadence.
        let delay: UInt64 = failures == 0 ? 60 : (15 << (failures - 1))
        do {
          try await Task.sleep(nanoseconds: delay * 1_000_000_000)
        } catch {
          return
        }
        guard let self else {
          return
        }
        await self.refresh()
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
  private static let launchAtLoginConfiguredKey = "launch-at-login-configured-v1"

  func refreshLaunchAtLoginStatus() {
    launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
  }

  private func ensureLaunchAtLoginEnabled() {
    refreshLaunchAtLoginStatus()
    guard !languageDefaults.bool(forKey: Self.launchAtLoginConfiguredKey) else {
      return
    }
    // Register by default once. Later launches respect both the in-app toggle
    // and changes made in System Settings.
    if SMAppService.mainApp.status != .notRegistered {
      languageDefaults.set(true, forKey: Self.launchAtLoginConfiguredKey)
      return
    }

    do {
      try SMAppService.mainApp.register()
      languageDefaults.set(true, forKey: Self.launchAtLoginConfiguredKey)
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
    let hasTrustedQuotaMetadata =
      snapshot.accountFingerprint != nil && snapshot.rateLimitsJSON != nil
    var sharedSnapshot = SharedUsageSnapshot(
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
      lifetimeTokens: snapshot.tokenUsage?.lifetimeTokens,
      accountFingerprint: hasTrustedQuotaMetadata
        ? snapshot.accountFingerprint : nil,
      rateLimitsJSON: hasTrustedQuotaMetadata
        ? snapshot.rateLimitsJSON : nil,
      quotaSourceVersion: hasTrustedQuotaMetadata ? 1 : nil
    )

    if let encoded = try? JSONEncoder().encode(sharedSnapshot) {
      if encoded.count > LocalUsageSnapshotBridgeConfiguration.maximumPayloadSize {
        sharedSnapshot = sharedSnapshot.withoutQuotaMetadata()
      }
    } else {
      sharedSnapshot = sharedSnapshot.withoutQuotaMetadata()
    }

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
