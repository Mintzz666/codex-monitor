import CodexUsageShared
import Foundation
import SwiftUI

struct BadgeMonitorHealth: Decodable {
  let installed: Bool
  let running: Bool
  let signatureValid: Bool
  let version: String?
  let build: String?
}

struct BadgeHealthReport: Decodable {
  let checkedAt: String?
  let overall: String?
  let monitor: BadgeMonitorHealth?
  let quotaSnapshotFresh: Bool?
  let badgeBundleHashValid: Bool?
  let badgeActiveHashValid: Bool?
  let badgeManagerHashValid: Bool?
  let badgeActiveFilesValid: Bool?
  let badgeAgentRunning: Bool?
  let badgeStartupAgentRunning: Bool?
  let chatGPTInstalled: Bool?
  let cdpReachable: Bool?
  let mainWindowCount: Int?
  let injectedWindowCount: Int?
  let projectColorsVersion: Int?
  let threadTokensVersion: Int?
  let errors: [String]?
  let operationSucceeded: Bool?
  let operationMessage: String?
  let backupPath: String?
  let error: String?
}

@MainActor
final class BadgeIntegrationViewModel: ObservableObject {
  @Published private(set) var report: BadgeHealthReport?
  @Published private(set) var isWorking = false
  @Published private(set) var lastCommandError: String?
  private var lastCheckAt: Date?

  func refresh(force: Bool = false) {
    let cacheDuration: TimeInterval = isHealthy ? 30 : 5
    if !force, let lastCheckAt, Date().timeIntervalSince(lastCheckAt) < cacheDuration {
      return
    }
    run(action: "health")
  }

  func installOrRepair() {
    run(action: "install")
  }

  func summary(for language: AppLanguage) -> String {
    guard let report else {
      return language == .simplifiedChinese ? "尚未检查" : "Not checked"
    }
    if report.overall == "healthy" {
      return language == .simplifiedChinese ? "已连接" : "Connected"
    }
    if report.cdpReachable == false {
      return language == .simplifiedChinese ? "等待 ChatGPT 连接" : "Waiting for ChatGPT"
    }
    if report.quotaSnapshotFresh == false {
      return language == .simplifiedChinese ? "额度桥不可用" : "Quota bridge unavailable"
    }
    return language == .simplifiedChinese ? "需要检查" : "Needs attention"
  }

  var isHealthy: Bool { report?.overall == "healthy" }

  private func run(action: String) {
    guard !isWorking else { return }
    guard
      let scriptURL = Bundle.main.resourceURL?
        .appendingPathComponent("CodexUsageBadge", isDirectory: true)
        .appendingPathComponent("health.cjs")
    else {
      lastCommandError = "The bundled appearance helper is missing."
      return
    }
    guard let nodeURL = Self.nodeURL else {
      lastCommandError = "ChatGPT's bundled Node.js runtime was not found."
      return
    }

    isWorking = true
    lastCommandError = nil
    Task { [weak self] in
      let output = await Task.detached(priority: .utility) {
        Self.execute(node: nodeURL, script: scriptURL, action: action)
      }.value
      guard let self else { return }
      self.isWorking = false
      guard let report = try? JSONDecoder().decode(BadgeHealthReport.self, from: output.stdout)
      else {
        self.lastCommandError = output.error ?? "The appearance helper returned an invalid status."
        return
      }
      self.report = report
      self.lastCheckAt = Date()
      if output.status != 0 || report.operationSucceeded == false {
        self.lastCommandError =
          report.error ?? output.error ?? "The requested operation did not finish."
      } else {
        self.lastCommandError = nil
      }
    }
  }

  private static var nodeURL: URL? {
    let candidates = [
      "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node",
      "/Applications/Codex.app/Contents/Resources/cua_node/bin/node",
    ]
    return candidates.first(where: FileManager.default.isExecutableFile(atPath:)).map(
      URL.init(fileURLWithPath:))
  }

  private nonisolated static func execute(
    node: URL,
    script: URL,
    action: String
  ) -> CommandOutput {
    let process = Process()
    let output = Pipe()
    process.executableURL = node
    process.arguments = [script.path, action]
    process.standardOutput = output
    process.standardError = output
    process.environment = ProcessInfo.processInfo.environment.merging([
      "CODEX_BADGE_APP": "/Applications/ChatGPT.app",
      "CODEX_MONITOR_HEALTH_CALLER": "running-app",
    ]) { _, new in new }
    do {
      try process.run()
      // A stalled helper must not leave the controls disabled indefinitely.
      let deadline = DispatchWorkItem {
        if process.isRunning { process.terminate() }
      }
      DispatchQueue.global(qos: .utility).asyncAfter(
        deadline: .now() + (action == "install" ? 60 : 25),
        execute: deadline
      )
      defer { deadline.cancel() }
      let data = output.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      return CommandOutput(stdout: data, status: process.terminationStatus, error: nil)
    } catch {
      return CommandOutput(stdout: Data(), status: -1, error: error.localizedDescription)
    }
  }
}

private struct CommandOutput: Sendable {
  let stdout: Data
  let status: Int32
  let error: String?
}

struct BadgeIntegrationSettingsView: View {
  @ObservedObject var model: BadgeIntegrationViewModel
  @AppStorage(AppLanguage.storageKey)
  private var storedLanguage = AppLanguage.systemDefault.rawValue

  private var isChinese: Bool {
    AppLanguage.resolve(storedLanguage) == .simplifiedChinese
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 4) {
        Text(isChinese ? "ChatGPT 外观增强" : "ChatGPT Appearance")
          .font(.title2.weight(.semibold))
        Text(
          isChinese
            ? "Codex Monitor 与定制版 Codex Usage Badge 的连接状态。"
            : "Connection status for Codex Monitor and the customized Codex Usage Badge."
        )
        .font(.subheadline)
        .foregroundStyle(.secondary)
      }

      Divider()

      statusRow(
        isChinese ? "Codex Monitor" : "Codex Monitor",
        value: monitorValue,
        good: model.report?.monitor?.running == true
          && model.report?.monitor?.signatureValid == true
      )
      statusRow(
        isChinese ? "共享额度快照" : "Shared quota snapshot",
        value: yesNo(model.report?.quotaSnapshotFresh),
        good: model.report?.quotaSnapshotFresh == true
      )
      statusRow(
        isChinese ? "外观增强后台" : "Appearance agent",
        value: agentValue,
        good: model.report?.badgeAgentRunning == true && model.report?.badgeActiveHashValid == true
          && model.report?.badgeManagerHashValid == true
          && model.report?.badgeActiveFilesValid == true
      )
      statusRow(
        isChinese ? "登录启动助手" : "Login startup helper",
        value: model.report?.badgeStartupAgentRunning.map {
          $0 ? (isChinese ? "运行中" : "Running") : (isChinese ? "未运行" : "Not running")
        } ?? (isChinese ? "未检查" : "Not checked"),
        good: model.report?.badgeStartupAgentRunning == true
      )
      statusRow(
        "ChatGPT",
        value: chatGPTValue,
        good: model.report?.cdpReachable == true && (model.report?.injectedWindowCount ?? 0) > 0
      )

      if model.report?.cdpReachable == false || model.report?.mainWindowCount == 0 {
        Text(
          isChinese
            ? "正在使用的窗口会跳过自动重开。若仍未连接，请完全退出 ChatGPT（⌘Q），再从原图标重新打开，无需重新安装。"
            : "Windows already in use are skipped. If disconnected, quit ChatGPT with ⌘Q and reopen it from its usual icon. No reinstall is needed."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }

      if let lastCommandError = model.lastCommandError {
        Text(lastCommandError)
          .font(.callout)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      } else if let operationMessage = model.report?.operationMessage {
        Text(operationMessage)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack {
        if let backupPath = model.report?.backupPath {
          Text(isChinese ? "已保存回退副本：\(backupPath)" : "Rollback copy saved: \(backupPath)")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        Spacer()
        if model.isWorking { ProgressView().controlSize(.small) }
        Button(isChinese ? "立即检查" : "Check now") {
          model.refresh(force: true)
        }
        .disabled(model.isWorking)
        Button(isChinese ? "安装 / 更新 / 修复" : "Install / Update / Repair") {
          model.installOrRepair()
        }
        .disabled(model.isWorking)
      }
    }
    .padding(22)
    .frame(minWidth: 480, idealWidth: 520, minHeight: 310)
    .task { model.refresh() }
  }

  private var monitorValue: String {
    guard let monitor = model.report?.monitor else { return isChinese ? "未检查" : "Not checked" }
    guard monitor.running else { return isChinese ? "未运行" : "Not running" }
    let version = [monitor.version, monitor.build].compactMap { $0 }.joined(separator: " · Build ")
    return version.isEmpty ? (isChinese ? "运行中" : "Running") : version
  }

  private var agentValue: String {
    guard let report = model.report else { return isChinese ? "未检查" : "Not checked" }
    if report.badgeAgentRunning == true && report.badgeActiveHashValid == true
      && report.badgeManagerHashValid == true && report.badgeActiveFilesValid == true
    {
      return isChinese ? "运行中 · 定制版已核验" : "Running · customized build verified"
    }
    if report.badgeAgentRunning == false { return isChinese ? "未运行" : "Not running" }
    return isChinese ? "版本需修复" : "Build needs repair"
  }

  private var chatGPTValue: String {
    guard let report = model.report else { return isChinese ? "未检查" : "Not checked" }
    guard report.cdpReachable == true else {
      return isChinese ? "本地接口未连接" : "Local interface disconnected"
    }
    let count = report.injectedWindowCount ?? 0
    return count > 0
      ? (isChinese ? "已注入 · \(count) 个窗口" : "Injected · \(count) window(s)")
      : (isChinese ? "窗口未确认注入" : "Injection not confirmed")
  }

  private func yesNo(_ value: Bool?) -> String {
    guard let value else { return isChinese ? "未检查" : "Not checked" }
    return value
      ? (isChinese ? "有效且新鲜" : "Fresh and valid") : (isChinese ? "不可用或已过期" : "Unavailable or stale")
  }

  private func statusRow(_ title: String, value: String, good: Bool) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title)
      Spacer()
      Text(value)
        .foregroundStyle(good ? Color.primary : Color.orange)
        .multilineTextAlignment(.trailing)
    }
    .font(.callout)
  }
}
