import AppKit
import Charts
import CodexUsageCore
import CodexUsageShared
import SwiftUI

private struct MenuTokenChartPoint: Identifiable {
  let index: Int
  let bucket: DailyTokenUsage

  var id: String { bucket.id }
}

struct UsageMenuView: View {
  static let width: CGFloat = 344

  @ObservedObject var viewModel: UsageViewModel
  @ObservedObject var badgeIntegrationModel: BadgeIntegrationViewModel
  @Binding var language: AppLanguage

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      usageSection
      historySection
      appearanceSection

      if let errorMessage = viewModel.errorDisplayText(for: language) {
        errorPanel(errorMessage)
      }

      Divider()
      actionsSection
    }
    .padding(14)
    .frame(width: Self.width)
    .environment(\.locale, language.locale)
    .task {
      await viewModel.refreshIfStale()
      badgeIntegrationModel.refresh()
    }
  }

  @ViewBuilder
  private var appearanceSection: some View {
    if #available(macOS 14.0, *) {
      SettingsAppearanceSection(model: badgeIntegrationModel, language: $language)
    } else {
      WindowAppearanceSection(model: badgeIntegrationModel, language: $language)
    }
  }

  private var header: some View {
    HStack {
      VStack(alignment: .leading, spacing: 3) {
        Text("Codex Monitor")
          .font(.system(size: 16, weight: .bold, design: .rounded))
        Text(language.menuDateText(Date()))
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      Spacer()

      HStack(spacing: 10) {
        if viewModel.isLanguageSwitching {
          HStack(spacing: 4) {
            ProgressView()
              .controlSize(.small)
            Text(language.text(.switchingLanguage))
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
          .accessibilityElement(children: .combine)
          .accessibilityLabel(language.text(.switchingLanguage))
        } else if viewModel.isRefreshing {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel(language.text(.refreshing))
        }

        LanguageSwitcher(
          language: $language,
          pendingLanguage: viewModel.pendingDisplayLanguage,
          isSwitching: viewModel.isLanguageSwitching,
          switchingText: language.text(.switchingLanguage)
        )
      }
    }
  }

  private var usageSection: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2) {
          Text(language.text(.remainingQuota))
            .font(.headline)
          Text(
            "\(language.text(.weeklyUsed)) "
              + percentText(viewModel.snapshot?.usedPercent)
          )
          .font(.caption2)
          .foregroundStyle(.secondary)
        }
        Spacer()
        Text(percentText(viewModel.snapshot?.remainingPercent))
          .font(.system(size: 32, weight: .bold, design: .rounded))
          .monospacedDigit()
      }

      UsageProgressBar(
        value: viewModel.snapshot?.remainingPercent ?? 0,
        color: remainingColor
      )
      .accessibilityLabel(language.text(.remainingQuota))
      .accessibilityValue(percentText(viewModel.snapshot?.remainingPercent))

      ForEach(viewModel.snapshot?.additionalWindows ?? []) { window in
        additionalWindowSection(window)
      }

      Divider()
      detailsSection
    }
    .padding(12)
    .background(
      LinearGradient(
        colors: [
          Color.accentColor.opacity(0.13),
          Color.accentColor.opacity(0.035),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      ),
      in: RoundedRectangle(cornerRadius: 14, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(.primary.opacity(0.07), lineWidth: 1)
    }
  }

  private func additionalWindowSection(_ window: UsageWindow) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(windowDisplayName(window))
          .font(.subheadline.weight(.medium))
        Spacer()
        Text(percentText(window.remainingPercent))
          .font(.subheadline.weight(.semibold))
          .monospacedDigit()
      }

      UsageProgressBar(
        value: window.remainingPercent,
        color: remainingColor(for: window.remainingPercent)
      )
      .accessibilityLabel(windowDisplayName(window))
      .accessibilityValue(percentText(window.remainingPercent))

      HStack {
        Text(
          (language == .simplifiedChinese ? "已用 " : "Used ")
            + percentText(window.usedPercent)
        )
        Spacer()
        Text(
          "\(language.text(.resetTime)) "
            + language.resetDisplayText(window.resetsAt)
        )
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(.top, 2)
  }

  private var detailsSection: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Label(nextResetText, systemImage: "arrow.clockwise")
        .foregroundStyle(.secondary)
      Spacer()
      TimelineView(.periodic(from: .now, by: 60)) { context in
        VStack(alignment: .trailing, spacing: 3) {
          Text(viewModel.resetDisplayText(for: language))
            .fontWeight(.medium)
          if let countdown = language.resetCountdownText(
            viewModel.snapshot?.resetsAt,
            now: context.date
          ) {
            Text(countdown)
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
        .monospacedDigit()
        .accessibilityElement(children: .combine)
      }
    }
    .font(.caption)
  }

  private var historySection: some View {
    let resetEvents = Dictionary(
      (viewModel.resetRadar?.events ?? []).map { ($0.dateKey(), $0) },
      uniquingKeysWith: { first, _ in first }
    )
    return VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 2) {
          Text(historyTitle)
            .font(.subheadline.weight(.semibold))
          Text(historySubtitle)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        Spacer()
        VStack(alignment: .trailing, spacing: 2) {
          Text(language == .simplifiedChinese ? "今日" : "Today")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
          Text(latestDailyTokenText)
            .font(.subheadline.weight(.bold))
            .monospacedDigit()
        }
      }

      if menuTokenPoints.isEmpty {
        Text(
          language == .simplifiedChinese
            ? "暂无每日 Token 数据"
            : "No daily token data yet"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 124)
      } else {
        Chart(menuTokenPoints) { point in
          AreaMark(
            x: .value("Day", point.index),
            y: .value("Tokens", Double(point.bucket.tokens))
          )
          .foregroundStyle(
            LinearGradient(
              colors: [
                Color.accentColor.opacity(0.22),
                Color.accentColor.opacity(0.015),
              ],
              startPoint: .top,
              endPoint: .bottom
            )
          )

          LineMark(
            x: .value("Day", point.index),
            y: .value("Tokens", Double(point.bucket.tokens))
          )
          .foregroundStyle(Color.accentColor)
          .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))

          PointMark(
            x: .value("Day", point.index),
            y: .value("Tokens", Double(point.bucket.tokens))
          )
          .foregroundStyle(Color.accentColor)
          .symbolSize(point.index == menuTokenPoints.count - 1 ? 34 : 18)
          .accessibilityLabel(language.tokenFullDateLabel(point.bucket.startDate))
          .accessibilityValue("\(point.bucket.tokens) Token")
        }
        .chartXScale(domain: -0.3...6.3)
        .chartYScale(domain: 0...(menuTokenMaximum * 1.15))
        .chartYAxis {
          AxisMarks(values: .automatic(desiredCount: 3)) { value in
            AxisGridLine()
              .foregroundStyle(.secondary.opacity(0.13))
            AxisValueLabel {
              if let number = value.as(Double.self) {
                Text(tokenText(Int64(number.rounded())))
              }
            }
            .font(.system(size: 9))
          }
        }
        .chartXAxis {
          AxisMarks(values: Array(menuTokenPoints.indices)) { value in
            AxisGridLine().foregroundStyle(.clear)
            AxisValueLabel(
              centered: false,
              anchor: .top,
              collisionResolution: .disabled
            ) {
              if let index = value.as(Int.self),
                menuTokenPoints.indices.contains(index)
              {
                dayAxisLabel(menuTokenPoints[index])
              }
            }
          }
        }
        .chartOverlay { proxy in
          GeometryReader { geometry in
            ForEach(menuTokenPoints) { point in
              if let event = resetEvents[point.bucket.startDate],
                let x = proxy.position(forX: point.index)
              {
                Link(destination: event.sourceURL) {
                  Text("RESET")
                    .font(.system(size: 6.5, weight: .bold, design: .rounded))
                    .padding(.horizontal, 3)
                    .padding(.vertical, 2)
                    .foregroundStyle(Color.green)
                    .background(.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)
                .help(resetHelp(event))
                .accessibilityLabel(
                  "RESET · \(language.tokenFullDateLabel(point.bucket.startDate))"
                )
                .position(
                  x: geometry[proxy.plotAreaFrame].minX + x,
                  y: geometry[proxy.plotAreaFrame].maxY + 38
                )
              }
            }
          }
        }
        .frame(height: 138)
      }

      Divider()
      resetForecastSection
    }
    .padding(12)
    .background(
      .primary.opacity(0.04),
      in: RoundedRectangle(cornerRadius: 13, style: .continuous)
    )
  }

  private var menuTokenPoints: [MenuTokenChartPoint] {
    guard let dailyBuckets = viewModel.snapshot?.tokenUsage?.dailyBuckets,
      !dailyBuckets.isEmpty
    else { return [] }
    let buckets = DailyTokenSeries.sevenDaysEnding(
      on: Date(),
      buckets: dailyBuckets
    )
    return buckets.enumerated().map {
      MenuTokenChartPoint(index: $0.offset, bucket: $0.element)
    }
  }

  private var menuTokenMaximum: Double {
    Double(max(1, menuTokenPoints.map(\.bucket.tokens).max() ?? 1))
  }

  private var latestDailyTokenText: String {
    guard let tokens = menuTokenPoints.last?.bucket.tokens else {
      return "—"
    }
    return tokenText(tokens)
  }

  private var historyTitle: String {
    language == .simplifiedChinese ? "近 7 日 Token" : "Tokens · 7 days"
  }

  private var historySubtitle: String {
    guard let first = menuTokenPoints.first, let last = menuTokenPoints.last else {
      return language == .simplifiedChinese ? "每日用量" : "Daily usage"
    }
    let range =
      "\(language.tokenDateLabel(first.bucket.startDate))–"
      + language.tokenDateLabel(last.bucket.startDate)
    return range + (language == .simplifiedChinese ? " · 每日用量" : " · Daily usage")
  }

  private func tokenText(_ tokens: Int64) -> String {
    if tokens >= 1_000_000_000 {
      return "\(String(format: "%.1f", Double(tokens) / 1_000_000_000))B"
    }
    if tokens >= 1_000_000 {
      return "\(String(format: "%.1f", Double(tokens) / 1_000_000))M"
    }
    if tokens >= 1_000 {
      return "\(String(format: "%.1f", Double(tokens) / 1_000))K"
    }
    return "\(tokens)"
  }

  private func dayAxisLabel(_ point: MenuTokenChartPoint) -> some View {
    let isToday = point.index == menuTokenPoints.count - 1
    return VStack(spacing: 2) {
      Text(language.tokenDateLabel(point.bucket.startDate))
        .fontWeight(isToday ? .semibold : .regular)
        .monospacedDigit()
      Text(language.tokenWeekdayLabel(point.bucket.startDate))
        .opacity(isToday ? 1 : 0.7)
    }
    .font(.system(size: 9))
    .foregroundStyle(isToday ? Color.accentColor : Color.secondary)
    .padding(.horizontal, 3)
    .padding(.vertical, 3)
    .background(
      isToday ? Color.accentColor.opacity(0.10) : .clear,
      in: RoundedRectangle(cornerRadius: 5)
    )
    .padding(.bottom, 14)
  }

  private func resetHelp(_ event: GlobalResetEvent) -> String {
    let description =
      language == .simplifiedChinese
      ? "Tibo 全局重置完成记录（社区收录）"
      : "Tibo global reset confirmation (community archive)"
    return description + "\n" + language.resetDisplayText(event.confirmedAt)
      + " · " + TimeZone.current.identifier + "\n" + event.sourceURL.absoluteString
  }

  private var resetForecastSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Text(language == .simplifiedChinese ? "全局重置预测" : "Global reset")
          .font(.caption.weight(.semibold))
          .lineLimit(1)
        Spacer(minLength: 8)
        Text(radarStatusText)
          .font(.system(size: 9))
          .foregroundStyle(Color.secondary)
          .lineLimit(1)
      }
      HStack(spacing: 8) {
        forecastWindow(hours: 24, percent: viewModel.resetRadar?.forecast.percent24h)
        forecastWindow(hours: 48, percent: viewModel.resetRadar?.forecast.percent48h)
      }
      HStack {
        Link("codex-reset.com ↗", destination: ResetRadarClient.sourceURL)
          .buttonStyle(.plain)
          .foregroundStyle(Color.accentColor)
        Spacer()
        Text(
          (language == .simplifiedChinese ? "更新 " : "Updated ")
            + radarUpdateText
        )
        .foregroundStyle(.secondary)
      }
      .font(.system(size: 9))
    }
    .help(
      language == .simplifiedChinese
        ? "社区实验性概率，非官方时间表。RESET 为社区收录的 Tibo 完成记录，按本机时区显示；点击标记可看原帖。"
        : "Experimental community estimates. RESET marks link to archived Tibo confirmations in your local time zone."
    )
  }

  private func forecastWindow(hours: Int, percent: Double?) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text(language == .simplifiedChinese ? "\(hours)h 内" : "Within \(hours)h")
        .font(.caption2)
        .foregroundStyle(.secondary)
      Spacer(minLength: 0)
      Text(
        radarForecastIsCurrent && percent != nil
          ? "\(Int(percent!.rounded()))%" : "—"
      )
      .font(.system(size: 16, weight: .semibold, design: .rounded))
      .monospacedDigit()
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity)
    .background(Color.accentColor.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
  }

  private var radarForecastIsCurrent: Bool {
    viewModel.resetRadarError == nil && viewModel.resetRadar?.forecast.isFresh() == true
  }

  private var radarUpdateText: String {
    guard let date = viewModel.resetRadar?.forecast.updatedAt else { return "—" }
    let formatter = DateFormatter()
    formatter.locale = language.locale
    formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "M/d HH:mm"
    return formatter.string(from: date)
  }

  private var radarStatusText: String {
    if viewModel.resetRadarError != nil {
      return language == .simplifiedChinese ? "来源暂不可用" : "Source unavailable"
    }
    guard let forecast = viewModel.resetRadar?.forecast else {
      return language == .simplifiedChinese ? "等待来源" : "Waiting for source"
    }
    guard forecast.isFresh() else {
      return language == .simplifiedChinese ? "预测已过期" : "Forecast expired"
    }
    switch forecast.confidence {
    case "low": return language == .simplifiedChinese ? "社区 · 低置信度" : "Community · Low"
    case "medium": return language == .simplifiedChinese ? "社区 · 中置信度" : "Community · Medium"
    case "high": return language == .simplifiedChinese ? "社区 · 高置信度" : "Community · High"
    default: return language == .simplifiedChinese ? "社区估计" : "Community estimate"
    }
  }

  private var nextResetText: String {
    language == .simplifiedChinese ? "下次额度重置" : "Next quota reset"
  }

  private var actionsSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Toggle(
          language.text(.launchAtLogin),
          isOn: Binding(
            get: { viewModel.launchAtLoginEnabled },
            set: { viewModel.setLaunchAtLogin($0) }
          )
        )
        .toggleStyle(CompactSwitchToggleStyle())
        .fixedSize()
        Spacer(minLength: 4)
        Text(viewModel.lastUpdatedDisplayText(for: language))
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
          .help("\(language.text(.refreshTime)) · \(autoRefreshText)")
        Button {
          Task { await viewModel.refresh(forceRadar: true) }
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .keyboardShortcut("r")
        .disabled(viewModel.isRefreshing)
        .help(language.text(.refreshNow))
        .accessibilityLabel(language.text(.refreshNow))
        Button(language.text(.quit)) {
          NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
      }
      .font(.caption)
      .buttonStyle(.plain)

      if let launchAtLoginError =
        viewModel.launchAtLoginErrorText(for: language)
      {
        Text(launchAtLoginError)
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var autoRefreshText: String {
    language == .simplifiedChinese
      ? "每分钟自动更新"
      : "Updates every minute"
  }

  private var remainingColor: Color {
    remainingColor(for: viewModel.snapshot?.remainingPercent)
  }

  private func remainingColor(for remainingPercent: Double?) -> Color {
    guard let remaining = remainingPercent else {
      return .secondary
    }
    if remaining <= 10 {
      return .red
    }
    if remaining <= 25 {
      return .orange
    }
    return .green
  }

  private func errorPanel(_ message: String) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
      Text(message)
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(10)
    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
  }

  private func percentText(_ value: Double?) -> String {
    guard let value else {
      return "--"
    }
    return "\(Int(value.rounded()))%"
  }

  private func windowDisplayName(_ window: UsageWindow) -> String {
    if let label = window.label, !label.isEmpty, label.lowercased() != "codex" {
      return label
    }
    let minutes = window.windowDurationMinutes
    if minutes % 1_440 == 0 {
      let days = minutes / 1_440
      return language == .simplifiedChinese ? "\(days) 天窗口" : "\(days)-day window"
    }
    if minutes % 60 == 0 {
      let hours = minutes / 60
      return language == .simplifiedChinese ? "\(hours) 小时窗口" : "\(hours)-hour window"
    }
    return language == .simplifiedChinese ? "\(minutes) 分钟窗口" : "\(minutes)-minute window"
  }
}

private struct AppearanceIntegrationRow: View {
  @ObservedObject var model: BadgeIntegrationViewModel
  @Binding var language: AppLanguage
  let onOpen: () -> Void

  var body: some View {
    Button(action: onOpen) {
      HStack(spacing: 8) {
        Image(systemName: model.isHealthy ? "circle.fill" : "circle.dashed")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(model.isHealthy ? Color.green : Color.orange)
        Text(language == .simplifiedChinese ? "ChatGPT 外观增强" : "ChatGPT appearance")
          .font(.caption.weight(.medium))
        Spacer(minLength: 4)
        if model.isWorking {
          ProgressView().controlSize(.mini)
        } else {
          Text(model.summary(for: language))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Image(systemName: "chevron.right")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(.tertiary)
      }
      .contentShape(Rectangle())
      .padding(.vertical, 3)
    }
    .buttonStyle(.plain)
    .help(
      language == .simplifiedChinese
        ? "查看连接状态并管理外观增强" : "Check connection and manage the appearance add-on"
    )
    .accessibilityLabel(
      language == .simplifiedChinese
        ? "ChatGPT 外观增强，\(model.summary(for: language))"
        : "ChatGPT appearance, \(model.summary(for: language))")
  }
}

@available(macOS 14.0, *)
private struct SettingsAppearanceSection: View {
  @ObservedObject var model: BadgeIntegrationViewModel
  @Binding var language: AppLanguage
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    AppearanceIntegrationRow(model: model, language: $language) {
      openSettings()
    }
  }
}

private struct WindowAppearanceSection: View {
  @ObservedObject var model: BadgeIntegrationViewModel
  @Binding var language: AppLanguage
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    AppearanceIntegrationRow(model: model, language: $language) {
      openWindow(id: "badge-integration")
    }
  }
}

private struct LanguageSwitcher: View {
  @Binding var language: AppLanguage
  let pendingLanguage: AppLanguage?
  let isSwitching: Bool
  let switchingText: String

  var body: some View {
    HStack(spacing: 2) {
      languageButton(
        title: "中",
        value: .simplifiedChinese,
        accessibilityLabel: "中文"
      )
      languageButton(
        title: "EN",
        value: .english,
        accessibilityLabel: "English"
      )
    }
    .padding(2)
    .background(
      .secondary.opacity(0.12),
      in: RoundedRectangle(cornerRadius: 7, style: .continuous)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel(language.text(.languagePicker))
  }

  private func languageButton(
    title: String,
    value: AppLanguage,
    accessibilityLabel: String
  ) -> some View {
    let isPending = isSwitching && pendingLanguage == value

    return Button {
      language = value
    } label: {
      ZStack {
        Text(title)
          .font(.system(size: 10, weight: .semibold, design: .rounded))
          .opacity(isPending ? 0 : 1)

        if isPending {
          ProgressView()
            .controlSize(.mini)
            .accessibilityHidden(true)
        }
      }
      .foregroundStyle(language == value ? .primary : .secondary)
      .frame(width: 32, height: 20)
      .background(
        language == value
          ? Color(nsColor: .controlBackgroundColor)
          : .clear,
        in: RoundedRectangle(cornerRadius: 5, style: .continuous)
      )
      .shadow(
        color: language == value ? .black.opacity(0.12) : .clear,
        radius: 1,
        y: 1
      )
    }
    .buttonStyle(.plain)
    .disabled(isSwitching)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityValue(isPending ? switchingText : "")
    .help(isPending ? switchingText : accessibilityLabel)
  }
}

private struct UsageProgressBar: View {
  let value: Double
  let color: Color

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule()
          .fill(.secondary.opacity(0.18))

        Capsule()
          .fill(
            LinearGradient(
              colors: [color.opacity(0.72), color],
              startPoint: .leading,
              endPoint: .trailing
            )
          )
          .frame(
            width: geometry.size.width * min(1, max(0, value / 100))
          )
          .shadow(color: color.opacity(0.28), radius: 3, y: 1)
      }
    }
    .frame(height: 9)
  }
}

private struct CompactSwitchToggleStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    Button {
      configuration.isOn.toggle()
    } label: {
      HStack(spacing: 6) {
        configuration.label
        Capsule()
          .fill(configuration.isOn ? Color.accentColor : .secondary.opacity(0.25))
          .frame(width: 26, height: 16)
          .overlay(alignment: configuration.isOn ? .trailing : .leading) {
            Circle()
              .fill(.white)
              .padding(2)
              .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
          }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
