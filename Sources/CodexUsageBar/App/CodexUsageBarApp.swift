import AppKit
import CodexUsageShared
import SwiftUI

@main
struct CodexUsageBarApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    Settings {
      EmptyView()
    }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private let viewModel = UsageViewModel()
  private var statusBarController: StatusBarController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApplication.shared.setActivationPolicy(.accessory)

    if let epdSnapshotPath {
      renderEPDSnapshot(to: epdSnapshotPath)
      return
    }

    if let documentationSnapshotPath {
      renderDocumentationSnapshot(to: documentationSnapshotPath)
      return
    }

    statusBarController = StatusBarController(viewModel: viewModel)
    Task {
      await viewModel.activate()
    }
  }

  private var documentationSnapshotPath: String? {
    ProcessInfo.processInfo.environment[
      "CODEX_USAGE_BAR_DOCUMENTATION_SNAPSHOT"
    ]
  }

  private var epdSnapshotPath: String? {
    ProcessInfo.processInfo.environment[
      "CODEX_USAGE_BAR_EPD_SNAPSHOT"
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

  private func renderEPDSnapshot(to path: String) {
    viewModel.loadDocumentationPreview(subscription: .codex)
    do {
      try viewModel.writeEPDDocumentationPreview(to: path)
    } catch {
      fputs("EPD snapshot failed: \(error)\n", stderr)
    }
    NSApplication.shared.terminate(nil)
  }
}
