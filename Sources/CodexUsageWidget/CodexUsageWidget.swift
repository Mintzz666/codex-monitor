import Charts
import CodexUsageShared
import SwiftUI
import WidgetKit

private struct UsageTimelineEntry: TimelineEntry {
  let date: Date
  let snapshot: SharedUsageSnapshot?
  let languageCode: String?
  let subscriptionID: String?

  init(
    date: Date,
    snapshot: SharedUsageSnapshot?,
    languageCode: String? = nil,
    subscriptionID: String? = nil
  ) {
    self.date = date
    self.snapshot = snapshot
    self.languageCode = languageCode
    self.subscriptionID = subscriptionID
  }
}

private struct TokenChartPoint: Identifiable {
  let index: Int
  let bucket: SharedDailyTokenUsage

  var id: String { bucket.id }
}

private struct UsageTimelineProvider: TimelineProvider {
  private let appGroupStore = SharedUsageStore()
  private let widgetCacheStore = SharedUsageStore(
    directoryURL: Self.widgetCacheDirectory
  )
  private let appGroupPreferencesStore = SharedWidgetPreferencesStore()
  private let widgetPreferencesCacheStore = SharedWidgetPreferencesStore(
    directoryURL: Self.widgetCacheDirectory
  )
  private let localClient = LocalUsageSnapshotClient()

  func placeholder(in context: Context) -> UsageTimelineEntry {
    UsageTimelineEntry(date: Date(), snapshot: .placeholder)
  }

  func getSnapshot(
    in context: Context,
    completion: @escaping (UsageTimelineEntry) -> Void
  ) {
    if context.isPreview {
      completion(UsageTimelineEntry(date: Date(), snapshot: .placeholder))
      return
    }
    loadSnapshot { snapshot, languageCode, subscriptionID in
      completion(
        UsageTimelineEntry(
          date: Date(),
          snapshot: snapshot,
          languageCode: languageCode,
          subscriptionID: subscriptionID
        )
      )
    }
  }

  func getTimeline(
    in context: Context,
    completion: @escaping (Timeline<UsageTimelineEntry>) -> Void
  ) {
    loadSnapshot { snapshot, languageCode, subscriptionID in
      let now = Date()
      let entry = UsageTimelineEntry(
        date: now,
        snapshot: snapshot,
        languageCode: languageCode,
        subscriptionID: subscriptionID
      )
      let routineRefresh = now.addingTimeInterval(60)
      let refreshDate =
        snapshot?.resetsAt.map {
          min(routineRefresh, max(now.addingTimeInterval(60), $0))
        } ?? routineRefresh

      completion(
        Timeline(entries: [entry], policy: .after(refreshDate))
      )
    }
  }

  private func loadSnapshot(
    completion: @escaping (SharedUsageSnapshot?, String?, String?) -> Void
  ) {
    let sharedPreferences = appGroupPreferencesStore.load()
    let sharedLanguageCode = sharedPreferences?.languageCode
    let sharedSubscriptionID = sharedPreferences?.subscriptionID

    if let snapshot = appGroupStore.load() {
      completion(
        snapshot,
        sharedLanguageCode ?? snapshot.languageCode,
        sharedSubscriptionID ?? snapshot.subscriptionID
      )
      return
    }

    localClient.loadPayload { payload in
      let snapshot = payload?.snapshot ?? widgetCacheStore.load()
      let languageCode =
        payload?.languageCode
        ?? sharedLanguageCode
        ?? widgetPreferencesCacheStore.load()?.languageCode
        ?? snapshot?.languageCode
      let subscriptionID =
        sharedSubscriptionID
        ?? snapshot?.subscriptionID

      if let networkSnapshot = payload?.snapshot {
        try? widgetCacheStore.save(networkSnapshot)
      }
      if let languageCode {
        try? widgetPreferencesCacheStore.save(
          SharedWidgetPreferences(
            languageCode: languageCode,
            subscriptionID: subscriptionID
          )
        )
      }

      completion(snapshot, languageCode, subscriptionID)
    }
  }

  private static let widgetCacheDirectory =
    FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    )[0]
    .appendingPathComponent(
      "CodexUsageWidget",
      isDirectory: true
    )
}

private struct UsageWidgetView: View {
  @Environment(\.widgetFamily) private var family

  let entry: UsageTimelineEntry

  private var language: AppLanguage {
    AppLanguage.resolve(
      entry.languageCode ?? entry.snapshot?.languageCode
    )
  }

  var body: some View {
    Group {
      if let snapshot = entry.snapshot {
        switch family {
        case .systemLarge:
          largeContent(snapshot)
        case .systemMedium:
          mediumContent(snapshot)
        default:
          mediumContent(snapshot)
        }
      } else {
        emptyContent
      }
    }
    .modifier(WidgetBackgroundModifier())
    .environment(\.locale, language.locale)
    .accessibilityElement(children: .combine)
  }

  private func mediumContent(
    _ snapshot: SharedUsageSnapshot
  ) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      header(snapshot)

      HStack(alignment: .lastTextBaseline) {
        VStack(alignment: .leading, spacing: 1) {
          Text(language.text(.remainingQuota))
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(percentText(snapshot.remainingPercent))
            .font(.system(size: 30, weight: .bold, design: .rounded))
            .monospacedDigit()
        }
        Spacer()
        Text(planDisplayName(snapshot))
          .font(.caption.weight(.semibold))
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(
            Color.accentColor.opacity(0.12),
            in: Capsule()
          )
      }

      quotaBar(snapshot)

      HStack(spacing: 8) {
        metricPill(
          language.text(.weeklyUsed),
          percentText(snapshot.usedPercent)
        )
        metricPill(
          language.text(.resetTime),
          language.resetDisplayText(snapshot.resetsAt)
        )
      }
    }
    .padding(14)
  }

  private func largeContent(
    _ snapshot: SharedUsageSnapshot
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      header(snapshot)

      VStack(alignment: .leading, spacing: 7) {
        HStack(alignment: .lastTextBaseline) {
          VStack(alignment: .leading, spacing: 2) {
            Text(language.text(.remainingQuota))
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(.secondary)
            Text(percentText(snapshot.remainingPercent))
              .font(.system(size: 32, weight: .bold, design: .rounded))
              .monospacedDigit()
          }
          Spacer()
          VStack(alignment: .trailing, spacing: 3) {
            Text(planDisplayName(snapshot))
              .font(.caption.weight(.bold))
            Text(language.resetDisplayText(snapshot.resetsAt))
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }

        quotaBar(snapshot)

        HStack {
          Text(
            "\(language.text(.weeklyUsed)) "
              + percentText(snapshot.usedPercent)
          )
          Spacer()
          if let lifetimeTokens = snapshot.lifetimeTokens {
            Text(
              (language == .simplifiedChinese ? "累计 " : "Lifetime ")
                + tokenText(lifetimeTokens)
            )
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      .padding(10)
      .background(
        Color.accentColor.opacity(0.08),
        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
      )

      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text(language == .simplifiedChinese ? "最近 7 天 Token" : "Tokens · last 7 days")
            .font(.subheadline.weight(.semibold))
          Spacer()
          Text(latestDailyTokenText(snapshot))
            .font(.caption.weight(.semibold))
            .monospacedDigit()
        }

        tokenChart(snapshot)
          .frame(height: 74)
      }
      .padding(10)
      .background(
        .primary.opacity(0.04),
        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
      )

      HStack {
        resetText(snapshot)
        Spacer()
        Text(updatedText(snapshot))
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .padding(6)
  }

  private var emptyContent: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("CODEX MONITOR", systemImage: "chart.bar.fill")
        .font(.headline)

      Spacer()

      Text(language.widgetWaitingTitle)
        .font(.title3.weight(.semibold))
      Text(language.widgetWaitingBody)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(16)
  }

  private func header(
    _ snapshot: SharedUsageSnapshot
  ) -> some View {
    HStack(spacing: 6) {
      ZStack {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .fill(Color.accentColor.opacity(0.14))
        Text(">_")
          .font(.system(size: 8, weight: .black, design: .monospaced))
          .foregroundStyle(Color.accentColor)
      }
      .frame(width: 22, height: 22)

      Text("Codex Monitor")
        .font(.system(size: 14, weight: .bold, design: .rounded))
        .lineLimit(1)
        .minimumScaleFactor(0.72)
        .allowsTightening(true)
      Spacer(minLength: 4)
      if snapshot.isStale() {
        Image(systemName: "clock.badge.exclamationmark")
          .foregroundStyle(.orange)
          .help(language.widgetStaleHelp)
      } else {
        Circle()
          .fill(progressColor(snapshot.remainingPercent))
          .frame(width: 7, height: 7)
          .accessibilityHidden(true)
      }
    }
  }

  private func quotaBar(
    _ snapshot: SharedUsageSnapshot
  ) -> some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule()
          .fill(.secondary.opacity(0.15))
        Capsule()
          .fill(
            LinearGradient(
              colors: [
                progressColor(snapshot.remainingPercent).opacity(0.7),
                progressColor(snapshot.remainingPercent),
              ],
              startPoint: .leading,
              endPoint: .trailing
            )
          )
          .frame(
            width: geometry.size.width
              * min(1, max(0, snapshot.remainingPercent / 100))
          )
          .shadow(
            color: progressColor(snapshot.remainingPercent).opacity(0.25),
            radius: 3,
            y: 1
          )
      }
    }
    .frame(height: family == .systemLarge ? 11 : 10)
    .accessibilityLabel(language.text(.remainingQuota))
    .accessibilityValue(percentText(snapshot.remainingPercent))
  }

  private func metricPill(_ title: String, _ value: String) -> some View {
    HStack(spacing: 4) {
      Text(title)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Spacer(minLength: 3)
      Text(value)
        .fontWeight(.semibold)
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.72)
    }
    .font(.caption2)
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity)
    .background(
      .primary.opacity(0.045),
      in: RoundedRectangle(cornerRadius: 8, style: .continuous)
    )
  }

  private func planDisplayName(_ snapshot: SharedUsageSnapshot) -> String {
    guard let planType = snapshot.planType, !planType.isEmpty else {
      return "Codex"
    }
    if planType.lowercased() == "prolite" {
      return "Pro"
    }
    return planType.prefix(1).uppercased() + planType.dropFirst()
  }

  private func resetText(
    _ snapshot: SharedUsageSnapshot
  ) -> some View {
    HStack(spacing: 5) {
      Image(systemName: "arrow.clockwise")
      Text(language.widgetResetText(snapshot.resetsAt))
    }
    .font(.caption2)
    .foregroundStyle(.secondary)
  }

  private func compactRow(
    _ title: String,
    _ value: String
  ) -> some View {
    HStack(spacing: 4) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer(minLength: 4)
      Text(value)
        .font(.caption.weight(.semibold))
        .monospacedDigit()
    }
  }

  private func progressColor(_ remainingPercent: Double) -> Color {
    if remainingPercent <= 10 {
      return .red
    }
    if remainingPercent <= 25 {
      return .orange
    }
    return .green
  }

  private func percentText(_ value: Double) -> String {
    "\(Int(value.rounded()))%"
  }

  private func updatedText(
    _ snapshot: SharedUsageSnapshot
  ) -> String {
    language.widgetUpdatedText(
      snapshot.updatedAt,
      isStale: snapshot.isStale()
    )
  }

  private func tokenChart(_ snapshot: SharedUsageSnapshot) -> some View {
    let buckets = Array((snapshot.dailyTokenUsage ?? []).suffix(7))
    let points = buckets.enumerated().map {
      TokenChartPoint(index: $0.offset, bucket: $0.element)
    }
    let maximum = Double(max(1, buckets.map(\.tokens).max() ?? 1))

    return Group {
      if buckets.isEmpty {
        Text(language == .simplifiedChinese ? "暂无每日 Token 数据" : "No daily token data yet")
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        Chart(points) { point in
          AreaMark(
            x: .value("Day", point.index),
            y: .value("Tokens", Double(point.bucket.tokens))
          )
          .foregroundStyle(
            LinearGradient(
              colors: [Color.accentColor.opacity(0.3), Color.accentColor.opacity(0.02)],
              startPoint: .top,
              endPoint: .bottom
            )
          )

          LineMark(
            x: .value("Day", point.index),
            y: .value("Tokens", Double(point.bucket.tokens))
          )
          .foregroundStyle(Color.accentColor)
          .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

          PointMark(
            x: .value("Day", point.index),
            y: .value("Tokens", Double(point.bucket.tokens))
          )
          .foregroundStyle(Color.accentColor)
          .symbolSize(18)
        }
        .chartYScale(domain: 0...(maximum * 1.15))
        .chartYAxis {
          AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
            AxisGridLine()
              .foregroundStyle(.secondary.opacity(0.12))
            AxisValueLabel {
              if let number = value.as(Double.self) {
                Text(tokenText(Int64(number.rounded())))
                  .font(.system(size: 7))
              }
            }
          }
        }
        .chartXAxis {
          AxisMarks(values: Array(buckets.indices)) { value in
            AxisValueLabel {
              if let index = value.as(Int.self), buckets.indices.contains(index) {
                Text(shortDate(buckets[index].startDate))
                  .font(.system(size: 8))
              }
            }
          }
        }
      }
    }
  }

  private func latestDailyTokenText(_ snapshot: SharedUsageSnapshot) -> String {
    guard let tokens = snapshot.dailyTokenUsage?.suffix(7).last?.tokens else {
      return "—"
    }
    return tokenText(tokens)
  }

  private func tokenText(_ tokens: Int64) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 1
    if tokens >= 1_000_000 {
      return "\(String(format: "%.1f", Double(tokens) / 1_000_000))M"
    }
    if tokens >= 1_000 {
      return "\(String(format: "%.1f", Double(tokens) / 1_000))K"
    }
    return formatter.string(from: NSNumber(value: tokens)) ?? "\(tokens)"
  }

  private func shortDate(_ value: String) -> String {
    let pieces = value.split(separator: "-")
    guard pieces.count == 3 else { return value }
    return "\(pieces[1])/\(pieces[2])"
  }

  private func windowDisplayName(_ window: SharedUsageWindow) -> String {
    if let label = window.label, !label.isEmpty, label.lowercased() != "codex" {
      return label
    }
    let minutes = window.windowDurationMinutes
    if minutes % 60 == 0 {
      let hours = minutes / 60
      return language == .simplifiedChinese ? "\(hours) 小时窗口" : "\(hours)-hour window"
    }
    return language == .simplifiedChinese ? "其他窗口" : "Other window"
  }
}

private struct WidgetBackgroundModifier: ViewModifier {
  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(macOS 14.0, *) {
      content.containerBackground(for: .widget) {
        LinearGradient(
          colors: [
            Color.accentColor.opacity(0.12),
            Color.primary.opacity(0.035),
          ],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      }
    } else {
      content.background(
        LinearGradient(
          colors: [
            Color.accentColor.opacity(0.12),
            Color.primary.opacity(0.035),
          ],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      )
    }
  }
}

extension SharedUsageSnapshot {
  fileprivate static let placeholder = SharedUsageSnapshot(
    usedPercent: 64,
    resetsAt: Date().addingTimeInterval(3 * 24 * 60 * 60),
    planType: "pro",
    limitName: "Codex",
    updatedAt: Date(),
    languageCode: AppLanguage.systemDefault.rawValue
  )
}

struct CodexUsageWidget: Widget {
  private let language = AppLanguage.resolve(
    SharedWidgetPreferencesStore().load()?.languageCode
  )

  var body: some WidgetConfiguration {
    StaticConfiguration(
      kind: SharedUsageConfiguration.widgetKind,
      provider: UsageTimelineProvider()
    ) { entry in
      UsageWidgetView(entry: entry)
    }
    .configurationDisplayName(language.widgetDisplayName)
    .description(language.widgetDescription)
    .supportedFamilies([.systemMedium, .systemLarge])
  }
}

@main
struct CodexUsageWidgetBundle: WidgetBundle {
  var body: some Widget {
    CodexUsageWidget()
  }
}
