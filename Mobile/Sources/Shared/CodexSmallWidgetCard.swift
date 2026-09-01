import SwiftUI
import UIKit

struct CodexSmallWidgetCard: View {
  let snapshot: MobileUsageSnapshot
  var showsPreviewBadge = false
  var reservesInteractiveRefreshButton = false

  private var remainingText: String {
    "\(Int(snapshot.remainingPercent.rounded()))%"
  }

  private var resetText: String {
    let relative = RelativeDateTimeFormatter()
    relative.locale = Locale(identifier: "zh_CN")
    relative.unitsStyle = .short
    return relative.localizedString(for: snapshot.resetsAt, relativeTo: Date())
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 7) {
        codexLogo

        Text("CODEX")
          .font(.system(size: 12, weight: .bold, design: .rounded))
          .tracking(1.1)

        Spacer(minLength: 4)

        if showsPreviewBadge {
          Text("预览")
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
        }
      }

      Spacer(minLength: 8)

      Text("本周剩余")
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .foregroundStyle(.secondary)

      Text(remainingText)
        .font(.system(size: 39, weight: .bold, design: .rounded))
        .monospacedDigit()
        .minimumScaleFactor(0.75)
        .lineLimit(1)

      Spacer(minLength: 7)

      GeometryReader { proxy in
        ZStack(alignment: .leading) {
          Capsule()
            .fill(Color.primary.opacity(0.1))
          Capsule()
            .fill(progressColor)
            .frame(
              width: max(
                7,
                proxy.size.width * snapshot.remainingPercent / 100
              )
            )
        }
      }
      .frame(height: 7)

      Spacer(minLength: 8)

      HStack(spacing: 4) {
        if reservesInteractiveRefreshButton {
          Color.clear
            .frame(width: 25, height: 22)
        } else {
          Image(systemName: "arrow.clockwise")
            .font(.system(size: 9, weight: .semibold))
        }
        Text("\(resetText)重置")
          .font(.system(size: 10, weight: .semibold, design: .rounded))
          .lineLimit(1)
        Spacer(minLength: 2)
        Circle()
          .fill(Color.green)
          .frame(width: 6, height: 6)
      }
      .foregroundStyle(.secondary)
    }
    .padding(14)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Codex 本周剩余 \(remainingText)，\(resetText)重置")
  }

  private var progressColor: Color {
    switch snapshot.remainingPercent {
    case ..<20:
      return .red
    case ..<45:
      return .orange
    default:
      return Color(red: 0.28, green: 0.32, blue: 0.96)
    }
  }

  @ViewBuilder
  private var codexLogo: some View {
    if let image = UIImage(
      named: "AppIcon-1024",
      in: .main,
      compatibleWith: nil
    ) {
      Image(uiImage: image)
        .resizable()
        .scaledToFit()
        .frame(width: 23, height: 23)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .accessibilityHidden(true)
    } else {
      Image(systemName: "terminal.fill")
        .font(.system(size: 13, weight: .bold))
        .frame(width: 23, height: 23)
        .accessibilityHidden(true)
    }
  }
}
