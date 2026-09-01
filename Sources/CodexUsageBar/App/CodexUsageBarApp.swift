import AppKit
import CodexUsageShared
import Darwin
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

    if epdProbeRequested {
      runEPDHardwareProbe()
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

  private var epdProbeRequested: Bool {
    ProcessInfo.processInfo.environment[
      "CODEX_USAGE_BAR_EPD_PROBE"
    ] == "1"
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

  private func runEPDHardwareProbe() {
    Task {
      let transport = NRFEPDBluetoothTransport()
      do {
        writeProbeLine("EPD probe: scanning")
        let devices = try await transport.scan()
        writeProbeLine("EPD probe: found \(devices.count) compatible device(s)")
        for device in devices {
          let signal = device.signalStrength.map { "\($0) dBm" } ?? "unknown RSSI"
          let connectability =
            device.isConnectable.map {
              $0 ? "connectable" : "not connectable"
            } ?? "connectability unknown"
          writeProbeLine("- \(device.name): \(signal), \(connectability)")
        }

        if let target = preferredProbeDevice(from: devices) {
          writeProbeLine("EPD probe: connecting to \(target.name)")
          try await transport.connect(to: target)
          let information = try await transport.waitForInformation(
            timeoutNanoseconds: 8_000_000_000
          )
          writeProbeLine(
            "EPD probe: connected; \(information.driverDescription)"
          )
        }
      } catch {
        let message =
          (error as? LocalizedError)?.errorDescription
          ?? error.localizedDescription
        writeProbeLine("EPD probe failed: \(message)")
      }
      await transport.disconnect()
      exit(EXIT_SUCCESS)
    }
  }

  private func preferredProbeDevice(
    from devices: [EPDDeviceDescriptor]
  ) -> EPDDeviceDescriptor? {
    let preferred = devices.filter {
      NRFEPDDiscoveryPolicy.isPreferred8042($0.name)
    }
    let candidates = preferred.isEmpty ? devices : preferred
    return candidates.sorted {
      ($0.signalStrength ?? Int.min) > ($1.signalStrength ?? Int.min)
    }.first
  }

  private func writeProbeLine(_ message: String) {
    guard let data = "\(message)\n".data(using: .utf8) else { return }
    FileHandle.standardOutput.write(data)
  }
}
