import AppKit
import CodexUsageShared
import Combine
import Network
import SwiftUI

@main
struct CodexUsageBarApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @AppStorage(AppLanguage.storageKey)
  private var storedLanguage = AppLanguage.systemDefault.rawValue

  var body: some Scene {
    Settings {
      BadgeIntegrationSettingsView(model: appDelegate.badgeIntegrationModel)
    }
    Window(
      AppLanguage.resolve(storedLanguage) == .simplifiedChinese
        ? "ChatGPT 外观增强" : "ChatGPT Appearance",
      id: "badge-integration"
    ) {
      BadgeIntegrationSettingsView(model: appDelegate.badgeIntegrationModel)
    }
    .defaultSize(width: 520, height: 430)
    .windowResizability(.contentSize)
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private let viewModel = UsageViewModel()
  let badgeIntegrationModel = BadgeIntegrationViewModel()
  private var statusBarController: StatusBarController?
  private var wakeObserver: AnyCancellable?
  private var networkMonitor: NWPathMonitor?
  private var networkWasUnavailable = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApplication.shared.setActivationPolicy(.accessory)

    if let documentationSnapshotPath {
      renderDocumentationSnapshot(to: documentationSnapshotPath)
      return
    }

    statusBarController = StatusBarController(
      viewModel: viewModel,
      badgeIntegrationModel: badgeIntegrationModel
    )
    badgeIntegrationModel.refresh()
    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { [weak self] path in
      let available = path.status == .satisfied
      Task { @MainActor [weak self] in
        guard let self else { return }
        let recovered = available && self.networkWasUnavailable
        self.networkWasUnavailable = !available
        if recovered {
          await self.viewModel.refreshIfStale(maxAge: 0)
        }
      }
    }
    networkMonitor = monitor
    monitor.start(queue: DispatchQueue(label: "com.example.codexmonitor.network"))
    wakeObserver = NSWorkspace.shared.notificationCenter
      .publisher(for: NSWorkspace.didWakeNotification)
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        Task { @MainActor [weak self] in
          await self?.viewModel.refreshIfStale()
        }
      }
    Task {
      await viewModel.activate()
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    networkMonitor?.cancel()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  private var documentationSnapshotPath: String? {
    ProcessInfo.processInfo.environment[
      "CODEX_USAGE_BAR_DOCUMENTATION_SNAPSHOT"
    ]
  }

  private var documentationLanguage: AppLanguage {
    guard
      let value = ProcessInfo.processInfo.environment[
        "CODEX_USAGE_BAR_DOCUMENTATION_LANGUAGE"
      ],
      let language = AppLanguage(rawValue: value)
    else {
      return viewModel.displayLanguage
    }
    return language
  }

  private var documentationSubscription: UsageSubscription {
    UsageSubscription.resolve(
      ProcessInfo.processInfo.environment[
        "CODEX_USAGE_BAR_DOCUMENTATION_SUBSCRIPTION"
      ]
    )
  }

  private func renderDocumentationSnapshot(to path: String) {
    viewModel.loadDocumentationPreview(
      subscription: documentationSubscription
    )
    Task {
      if ProcessInfo.processInfo.environment["CODEX_USAGE_BAR_DOCUMENTATION_RADAR_LIVE"] == "1" {
        await viewModel.refreshResetRadarIfStale(force: true)
      }
      do {
        try DocumentationSnapshot.render(
          viewModel: viewModel,
          language: documentationLanguage,
          to: path
        )
      } catch {
        fputs("Documentation snapshot failed: \(error)\n", stderr)
      }
      NSApplication.shared.terminate(nil)
    }
  }
}
