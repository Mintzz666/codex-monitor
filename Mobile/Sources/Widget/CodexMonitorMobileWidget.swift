import AppIntents
import SwiftUI
import WidgetKit

struct RefreshCodexUsageIntent: AppIntent {
  static let title: LocalizedStringResource = "刷新 Codex 额度"
  static let description = IntentDescription(
    "在小组件中重新读取 Codex 额度，不打开主应用。"
  )
  static let openAppWhenRun = false

  func perform() async throws -> some IntentResult {
    _ = try? await CodexAccountService.shared.loadUsage()
    WidgetCenter.shared.reloadTimelines(ofKind: "CodexMonitorMobileWidget")
    return .result()
  }
}

private struct MobileUsageEntry: TimelineEntry {
  let date: Date
  let snapshot: MobileUsageSnapshot
  let isPreviewData: Bool
}

private struct MobileUsageTimelineProvider: TimelineProvider {
  private let liveProvider = OfficialAccountUsageProvider()
  private let storedProvider = StoredMobileUsageProvider()

  func placeholder(in context: Context) -> MobileUsageEntry {
    MobileUsageEntry(
      date: Date(),
      snapshot: .preview(),
      isPreviewData: true
    )
  }

  func getSnapshot(
    in context: Context,
    completion: @escaping (MobileUsageEntry) -> Void
  ) {
    if context.isPreview {
      completion(placeholder(in: context))
      return
    }
    loadEntry(completion: completion)
  }

  func getTimeline(
    in context: Context,
    completion: @escaping (Timeline<MobileUsageEntry>) -> Void
  ) {
    loadEntry { entry in
      let nextRefresh = Date().addingTimeInterval(15 * 60)
      completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }
  }

  private func loadEntry(
    completion: @escaping (MobileUsageEntry) -> Void
  ) {
    Task {
      do {
        let snapshot = try await liveProvider.loadUsage()
        completion(
          MobileUsageEntry(
            date: Date(),
            snapshot: snapshot,
            isPreviewData: false
          )
        )
      } catch {
        do {
          let snapshot = try await storedProvider.loadUsage()
          completion(
            MobileUsageEntry(
              date: Date(),
              snapshot: snapshot,
              isPreviewData: false
            )
          )
        } catch {
          completion(
            MobileUsageEntry(
              date: Date(),
              snapshot: .preview(),
              isPreviewData: true
            )
          )
        }
      }
    }
  }
}

private struct MobileUsageWidgetView: View {
  let entry: MobileUsageEntry

  var body: some View {
    ZStack(alignment: .bottomLeading) {
      CodexSmallWidgetCard(
        snapshot: entry.snapshot,
        showsPreviewBadge: entry.isPreviewData,
        reservesInteractiveRefreshButton: true
      )

      Button(intent: RefreshCodexUsageIntent()) {
        Image(systemName: "arrow.clockwise")
          .font(.system(size: 9, weight: .bold))
          .frame(width: 22, height: 22)
          .background(
            Color.primary.opacity(0.075),
            in: Circle()
          )
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("刷新 Codex 额度")
      .padding(.leading, 14)
      .padding(.bottom, 14)
    }
    .containerBackground(.background, for: .widget)
  }
}

struct CodexMonitorMobileWidget: Widget {
  let kind = "CodexMonitorMobileWidget"

  var body: some WidgetConfiguration {
    StaticConfiguration(
      kind: kind,
      provider: MobileUsageTimelineProvider()
    ) { entry in
      MobileUsageWidgetView(entry: entry)
    }
    .configurationDisplayName("Codex 本周额度")
    .description("快速查看 Codex 本周剩余额度和重置时间。")
    .supportedFamilies([.systemSmall])
    .contentMarginsDisabled()
  }
}

@main
struct CodexMonitorMobileWidgetBundle: WidgetBundle {
  var body: some Widget {
    CodexMonitorMobileWidget()
  }
}
