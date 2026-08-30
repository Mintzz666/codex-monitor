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
  @ObservedObject var viewModel: UsageViewModel
  @Binding var language: AppLanguage

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      header
      usageSection
      historySection

      if let errorMessage = viewModel.errorDisplayText(for: language) {
        errorPanel(errorMessage)
      }

      detailsSection
      epdSection
      Divider()
      actionsSection
    }
    .padding(18)
    .frame(width: 366)
    .environment(\.locale, language.locale)
    .task {
      await viewModel.refreshIfStale()
    }
  }

  private var header: some View {
    HStack {
      Image(nsImage: codexMonitorLogo)
        .resizable()
        .interpolation(.high)
        .scaledToFit()
        .scaleEffect(1.43)
        .frame(width: 46, height: 46)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        Text("Codex Monitor")
          .font(.system(size: 18, weight: .bold, design: .rounded))
        Text(
          language.text(.subtitle)
        )
        .font(.caption)
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

  private var codexMonitorLogo: NSImage {
    guard
      let url = Bundle.main.url(
        forResource: "AppIcon-1024",
        withExtension: "png"
      ),
      let image = NSImage(contentsOf: url)
    else {
      return NSImage()
    }
    return image
  }

  private var usageSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2) {
          Text(language.text(.remainingQuota))
            .font(.headline)
          Text(autoRefreshText)
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

      HStack {
        Text(language.text(.weeklyUsed))
          .foregroundStyle(.secondary)
        Spacer()
        Text(percentText(viewModel.snapshot?.usedPercent))
          .fontWeight(.medium)
          .monospacedDigit()
      }
      .font(.subheadline)

      ForEach(viewModel.snapshot?.additionalWindows ?? []) { window in
        additionalWindowSection(window)
      }
    }
    .padding(14)
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
          "\(language.text(.weeklyUsed)) "
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
    HStack(spacing: 10) {
      Image(systemName: "arrow.clockwise.circle.fill")
        .font(.system(size: 24))
        .foregroundStyle(Color.accentColor)

      VStack(alignment: .leading, spacing: 2) {
        Text(nextResetText)
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(viewModel.resetDisplayText(for: language))
          .font(.subheadline.weight(.semibold))
          .monospacedDigit()
      }

      Spacer()
    }
    .padding(12)
    .background(
      .primary.opacity(0.045),
      in: RoundedRectangle(cornerRadius: 12, style: .continuous)
    )
  }

  private var historySection: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(historyTitle)
            .font(.subheadline.weight(.semibold))
          Text(historySubtitle)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Text(latestDailyTokenText)
          .font(.subheadline.weight(.bold))
          .monospacedDigit()
      }

      if menuTokenPoints.isEmpty {
        Text(
          language == .simplifiedChinese
            ? "暂无每日 Token 数据"
            : "No daily token data yet"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 112)
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
          .symbolSize(24)
        }
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
            .font(.system(size: 8))
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
                Text(dayLabel(menuTokenPoints[index].bucket.startDate))
                  .font(.system(size: 8))
                  .monospacedDigit()
              }
            }
          }
        }
        .frame(height: 112)
      }
    }
    .padding(13)
    .background(
      .primary.opacity(0.04),
      in: RoundedRectangle(cornerRadius: 13, style: .continuous)
    )
  }

  private var menuTokenPoints: [MenuTokenChartPoint] {
    let buckets = DailyTokenSeries.sevenDaysEnding(
      on: Date(),
      buckets: viewModel.snapshot?.tokenUsage?.dailyBuckets ?? []
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
    language == .simplifiedChinese ? "近 7 日 Token 消耗" : "Daily tokens · 7 days"
  }

  private var historySubtitle: String {
    return language == .simplifiedChinese
      ? "每日独立统计 · 非累计"
      : "Daily values · not cumulative"
  }

  private func tokenText(_ tokens: Int64) -> String {
    if tokens >= 1_000_000 {
      return "\(String(format: "%.1f", Double(tokens) / 1_000_000))M"
    }
    if tokens >= 1_000 {
      return "\(String(format: "%.1f", Double(tokens) / 1_000))K"
    }
    return "\(tokens)"
  }

  private func dayLabel(_ value: String) -> String {
    let pieces = value.split(separator: "-")
    guard pieces.count == 3 else { return value }
    return Int(pieces[2]).map(String.init) ?? String(pieces[2])
  }

  private var nextResetText: String {
    language == .simplifiedChinese ? "下次额度重置" : "Next quota reset"
  }

  private var actionsSection: some View {
    VStack(spacing: 10) {
      HStack {
        Label(autoRefreshText, systemImage: "arrow.triangle.2.circlepath")
          .font(.caption)
          .foregroundStyle(.secondary)

        Spacer()

        Button(language.text(.quit)) {
          NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
      }

      Toggle(
        language.text(.launchAtLogin),
        isOn: Binding(
          get: { viewModel.launchAtLoginEnabled },
          set: { viewModel.setLaunchAtLogin($0) }
        )
      )
      .toggleStyle(CompactSwitchToggleStyle())

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

  private var epdSection: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 8) {
        Image(systemName: epdStatusSymbol)
          .foregroundStyle(epdStatusColor)
        VStack(alignment: .leading, spacing: 1) {
          Text(language == .simplifiedChinese ? "墨水屏" : "E-paper display")
            .font(.subheadline.weight(.semibold))
          Text(epdStatusText)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        Spacer()

        if viewModel.epdProbePhase.isBusy {
          ProgressView()
            .controlSize(.small)
        } else {
          Button(
            viewModel.epdInformation == nil
              ? (language == .simplifiedChinese ? "检测" : "Probe")
              : (language == .simplifiedChinese ? "重新检测" : "Probe again")
          ) {
            viewModel.probeEPD()
          }
          .controlSize(.small)
          .disabled(viewModel.isSendingEPDFrame)
        }
      }

      if let information = viewModel.epdInformation {
        HStack(spacing: 12) {
          epdMetric(
            title: language == .simplifiedChinese ? "设备" : "Device",
            value: information.device.name
          )
          epdMetric(
            title: language == .simplifiedChinese ? "固件" : "Firmware",
            value: information.firmwareVersion.map {
              String(format: "0x%02X", $0)
            } ?? "—"
          )
          epdMetric(
            title: "MTU",
            value: information.reportedMTU.map(String.init) ?? "—"
          )
          epdMetric(
            title: "RLE",
            value: information.supportsRLE ? "✓" : "—"
          )
        }
        Text(information.driverDescription)
          .font(.caption2.monospaced())
          .foregroundStyle(
            information.isStandardThreeColorDisplay
              ? Color.secondary : Color.orange
          )

        HStack {
          if viewModel.isSendingEPDFrame {
            ProgressView()
              .controlSize(.small)
            Text(
              language == .simplifiedChinese
                ? "正在连接并逐包同步实时画面…"
                : "Connecting and syncing live data…"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
          } else if information.isStandardThreeColorDisplay {
            Button(
              language == .simplifiedChinese
                ? "立即同步"
                : "Sync now"
            ) {
              viewModel.sendEPDLiveFrame()
            }
            .controlSize(.small)
          }
          Spacer()
        }

        if let sendMessage = viewModel.epdSendMessage {
          Text(epdSendDisplayText(sendMessage))
            .font(.caption2)
            .foregroundStyle(epdSendMessageColor(sendMessage))
        }
      } else {
        Text(
          language == .simplifiedChinese
            ? "可先检测设备；自动同步也会自行查找 NRF_EPD_8042。"
            : "Probe first, or let automatic sync find NRF_EPD_8042."
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
      }

      Text(
        language == .simplifiedChinese
          ? "每小时自动同步 · 跨日强制 · 画面相同则跳过 · 发送后断开"
          : "Hourly · forced after midnight · skips unchanged frames · disconnects after send"
      )
      .font(.system(size: 9))
      .foregroundStyle(.tertiary)
    }
    .padding(12)
    .background(
      .primary.opacity(0.04),
      in: RoundedRectangle(cornerRadius: 12, style: .continuous)
    )
  }

  private func epdMetric(title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(title)
        .font(.system(size: 8))
        .foregroundStyle(.tertiary)
      Text(value)
        .font(.caption2.monospaced())
        .lineLimit(1)
    }
  }

  private var epdStatusText: String {
    switch viewModel.epdProbePhase {
    case .idle:
      return language == .simplifiedChinese
        ? "自动同步已启用，空闲时蓝牙断开"
        : "Automatic sync enabled; Bluetooth is idle"
    case .scanning:
      return language == .simplifiedChinese ? "正在扫描附近设备…" : "Scanning…"
    case .connecting(let name):
      return language == .simplifiedChinese
        ? "正在连接 \(name)…"
        : "Connecting to \(name)…"
    case .reading(let name):
      return language == .simplifiedChinese
        ? "正在读取 \(name) 配置…"
        : "Reading \(name)…"
    case .ready:
      return language == .simplifiedChinese
        ? "设备已记住，空闲时蓝牙断开"
        : "Device remembered; Bluetooth is idle"
    case .failed(let message):
      return message
    }
  }

  private var epdStatusSymbol: String {
    switch viewModel.epdProbePhase {
    case .ready: return "checkmark.circle.fill"
    case .failed: return "exclamationmark.triangle.fill"
    case .scanning, .connecting, .reading: return "dot.radiowaves.left.and.right"
    case .idle: return "rectangle.connected.to.line.below"
    }
  }

  private var epdStatusColor: Color {
    switch viewModel.epdProbePhase {
    case .ready: return .green
    case .failed: return .orange
    case .scanning, .connecting, .reading: return .blue
    case .idle: return .secondary
    }
  }

  private func epdSendDisplayText(_ message: String) -> String {
    switch message {
    case "success":
      return language == .simplifiedChinese
        ? "同步完成，蓝牙已断开。"
        : "Sync complete; Bluetooth disconnected."
    case "auto-success":
      return language == .simplifiedChinese
        ? "自动同步完成，蓝牙已断开。"
        : "Automatic sync complete; Bluetooth disconnected."
    case "unchanged":
      return language == .simplifiedChinese
        ? "画面未变化，已跳过蓝牙传输。"
        : "Frame unchanged; Bluetooth transfer skipped."
    case "detected":
      return language == .simplifiedChinese
        ? "设备检测完成，蓝牙已断开。"
        : "Probe complete; Bluetooth disconnected."
    default:
      return message
    }
  }

  private func epdSendMessageColor(_ message: String) -> Color {
    switch message {
    case "success", "auto-success", "unchanged", "detected": return .green
    default: return .orange
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
      HStack {
        configuration.label
        Spacer()
        Capsule()
          .fill(configuration.isOn ? Color.accentColor : .secondary.opacity(0.25))
          .frame(width: 34, height: 20)
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
