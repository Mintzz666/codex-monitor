import AppKit
import CodexUsageCore
import CodexUsageShared
import SwiftUI

struct UsageMenuView: View {
  static let width: CGFloat = 344

  @ObservedObject var viewModel: UsageViewModel
  @ObservedObject var badgeIntegrationModel: BadgeIntegrationViewModel
  @Binding var language: AppLanguage

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      usageSection
      resetForecastSection
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
        Text(language.text(.remainingQuota))
          .font(.headline)
        Spacer(minLength: 4)
        if let geminiQuota = viewModel.geminiQuota {
          Text(geminiFreshnessText(geminiQuota.fetchedAt))
            .font(.system(size: 9))
            .foregroundStyle(
              viewModel.geminiQuotaIsStale ? Color.orange : Color.secondary
            )
            .lineLimit(1)
        } else if viewModel.geminiQuotaIsStale {
          Text(language == .simplifiedChinese ? "Gemini 暂不可用" : "Gemini unavailable")
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }

      quotaRow(
        label: language == .simplifiedChinese ? "Codex 周额度" : "Codex weekly",
        remainingPercent: viewModel.snapshot?.remainingPercent,
        resetsAt: viewModel.snapshot?.resetsAt,
        color: .primary,
        barHeight: 9
      )

      ForEach(viewModel.snapshot?.additionalWindows ?? []) { window in
        additionalWindowSection(window)
      }

      Divider()

      quotaRow(
        label: language == .simplifiedChinese ? "Gemini 周额度" : "Gemini weekly",
        remainingPercent: viewModel.geminiQuota?.weekly?.remainingPercent,
        resetsAt: viewModel.geminiQuota?.weekly?.resetsAt,
        color: .green,
        barHeight: 7
      )

      Divider()

      quotaRow(
        label: language == .simplifiedChinese ? "Gemini 5 小时额度" : "Gemini 5-hour",
        remainingPercent: viewModel.geminiQuota?.fiveHour?.remainingPercent,
        resetsAt: viewModel.geminiQuota?.fiveHour?.resetsAt,
        color: .blue,
        barHeight: 7,
        showsRelativeCountdown: true
      )
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

  private func quotaRow(
    label: String,
    remainingPercent: Double?,
    resetsAt: Date?,
    color: Color,
    barHeight: CGFloat,
    showsRelativeCountdown: Bool = false
  ) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(label)
          .font(.subheadline.weight(.semibold))
        Spacer(minLength: 8)
        Text(percentText(remainingPercent))
          .font(.system(size: 19, weight: .bold, design: .rounded))
          .monospacedDigit()
          .frame(minWidth: 42, alignment: .trailing)
      }

      UsageProgressBar(
        value: remainingPercent ?? 0,
        color: color,
        height: barHeight
      )
      .accessibilityLabel(label)
      .accessibilityValue(percentText(remainingPercent))

      if showsRelativeCountdown {
        TimelineView(.periodic(from: .now, by: 60)) { context in
          Text(relativeResetText(resetsAt, now: context.date))
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
      } else {
        Text(absoluteResetText(resetsAt))
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
    }
  }

  private func absoluteResetText(_ date: Date?) -> String {
    guard let date else {
      return language == .simplifiedChinese ? "重置时间未知" : "Reset time unknown"
    }
    let reset = language.resetDisplayText(date)
    return language == .simplifiedChinese
      ? "\(reset) 重置"
      : "Reset \(reset)"
  }

  private func relativeResetText(_ date: Date?, now: Date) -> String {
    guard let date else {
      return language == .simplifiedChinese ? "重置时间未知" : "Reset time unknown"
    }
    let secondsRemaining = date.timeIntervalSince(now)
    guard secondsRemaining > 0 else {
      return language == .simplifiedChinese ? "等待重置" : "Awaiting reset"
    }

    let totalMinutes = max(1, Int(ceil(secondsRemaining / 60)))
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    if language == .simplifiedChinese {
      if hours > 0 {
        return "\(hours) 小时 \(minutes) 分钟后重置"
      }
      return "\(minutes) 分钟后重置"
    }
    if hours > 0 {
      return "Resets in \(hours)h \(minutes)m"
    }
    return "Resets in \(minutes)m"
  }

  private func geminiFreshnessText(_ date: Date) -> String {
    let updated = language.lastUpdatedDisplayText(date)
    if viewModel.geminiQuotaIsStale {
      return language == .simplifiedChinese
        ? "Gemini 数据可能已过期 · \(updated)"
        : "Gemini data may be stale · \(updated)"
    }
    return language == .simplifiedChinese
      ? "Gemini 更新 · \(updated)"
      : "Gemini updated · \(updated)"
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
    .padding(12)
    .background(
      .primary.opacity(0.04),
      in: RoundedRectangle(cornerRadius: 13, style: .continuous)
    )
    .help(
      language == .simplifiedChinese
        ? "社区实验性概率，不是官方时间表。数据源为 codex-reset.com。"
        : "Experimental community estimates, not an official schedule. Source: codex-reset.com."
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
  let height: CGFloat

  init(value: Double, color: Color, height: CGFloat = 9) {
    self.value = value
    self.color = color
    self.height = height
  }

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
    .frame(height: height)
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
