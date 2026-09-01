import SwiftUI
import UIKit
import WidgetKit

@main
struct CodexMonitorMobileApp: App {
  var body: some Scene {
    WindowGroup { MobileHomeView() }
  }
}

private struct MobileHomeView: View {
  private enum LoginState: Equatable {
    case checking
    case signedOut
    case requestingCode
    case waitingForApproval(String)
    case signedIn
    case failed(String)
  }

  @Environment(\.openURL) private var openURL
  @State private var snapshot = MobileUsageSnapshotStore().load() ?? .preview()
  @State private var loginState: LoginState = .checking
  @State private var isRefreshing = false

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 24) {
          CodexSmallWidgetCard(
            snapshot: snapshot,
            showsPreviewBadge: loginState != .signedIn
          )
          .frame(width: 170, height: 170)
          .background(.background, in: RoundedRectangle(cornerRadius: 26))
          .shadow(color: .black.opacity(0.12), radius: 20, y: 8)
          .padding(.top, 24)

          accountPanel

          VStack(alignment: .leading, spacing: 12) {
            Label("账号令牌仅保存在 iPhone 钥匙串", systemImage: "lock.shield")
            Label("组件直接读取 Codex 周额度", systemImage: "chart.bar.fill")
            Label("不会读取或同步 Mac 登录信息", systemImage: "iphone")
          }
          .font(.subheadline)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(16)
          .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 32)
      }
      .navigationTitle("Codex Monitor")
      .task { await restoreSession() }
      .refreshable { await refreshUsage() }
    }
  }

  @ViewBuilder
  private var accountPanel: some View {
    VStack(spacing: 12) {
      switch loginState {
      case .checking:
        ProgressView("正在检查登录状态…")

      case .signedOut:
        Text("连接 Codex 账号")
          .font(.title3.bold())
        Text("使用 OpenAI 官方设备授权登录。登录过程在浏览器中完成，本 App 看不到你的密码。")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
        Button("使用 OpenAI 登录") {
          Task { await startLogin() }
        }
        .buttonStyle(.borderedProminent)

      case .requestingCode:
        ProgressView("正在向 OpenAI 获取登录码…")

      case .waitingForApproval(let code):
        Text("在 OpenAI 页面输入一次性代码")
          .font(.headline)
        Button {
          UIPasteboard.general.string = code
        } label: {
          Label(code, systemImage: "doc.on.doc")
            .font(.system(.title3, design: .monospaced, weight: .bold))
        }
        .buttonStyle(.bordered)
        Text("已打开官方登录页，授权完成后这里会自动刷新。代码 15 分钟内有效。")
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)

      case .signedIn:
        Label("已连接 Codex 账号", systemImage: "checkmark.circle.fill")
          .font(.headline)
          .foregroundStyle(.green)
        Button {
          Task { await refreshUsage() }
        } label: {
          if isRefreshing {
            ProgressView().controlSize(.small)
          } else {
            Label("立即刷新", systemImage: "arrow.clockwise")
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(isRefreshing)

        Button("退出账号", role: .destructive) {
          signOut()
        }
        .font(.footnote)

      case .failed(let message):
        Label(message, systemImage: "exclamationmark.triangle.fill")
          .font(.subheadline)
          .foregroundStyle(.orange)
          .multilineTextAlignment(.center)
        Button("重新登录") {
          Task { await startLogin() }
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(18)
    .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
  }

  @MainActor
  private func restoreSession() async {
    if await CodexAccountService.shared.isSignedIn() {
      loginState = .signedIn
      await refreshUsage()
    } else {
      loginState = .signedOut
    }
  }

  @MainActor
  private func startLogin() async {
    loginState = .requestingCode
    do {
      let authorization = try await CodexAccountService.shared.beginDeviceAuthorization()
      loginState = .waitingForApproval(authorization.userCode)
      openURL(authorization.verificationURL)
      let result = try await CodexAccountService.shared.finishDeviceAuthorization(authorization)
      snapshot = result
      loginState = .signedIn
      WidgetCenter.shared.reloadAllTimelines()
    } catch is CancellationError {
      loginState = .signedOut
    } catch {
      if await CodexAccountService.shared.isSignedIn() {
        // The browser round-trip may briefly interrupt the first usage request even
        // though OAuth already completed. Keep the valid session and let refresh retry.
        loginState = .signedIn
      } else {
        loginState = .failed(error.localizedDescription)
      }
    }
  }

  @MainActor
  private func refreshUsage() async {
    guard loginState == .signedIn else { return }
    isRefreshing = true
    defer { isRefreshing = false }
    do {
      snapshot = try await CodexAccountService.shared.loadUsage()
      WidgetCenter.shared.reloadAllTimelines()
    } catch {
      loginState = .failed(error.localizedDescription)
    }
  }

  private func signOut() {
    do {
      try CodexAccountService.shared.signOut()
      loginState = .signedOut
    } catch {
      loginState = .failed(error.localizedDescription)
    }
  }
}
