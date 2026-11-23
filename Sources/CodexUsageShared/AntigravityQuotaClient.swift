import Darwin
import Foundation

public struct GeminiQuotaWindow: Codable, Equatable, Sendable {
  public let remainingPercent: Double
  public let resetsAt: Date?

  public init(remainingPercent: Double, resetsAt: Date?) {
    self.remainingPercent = remainingPercent
    self.resetsAt = resetsAt
  }
}

public struct GeminiQuotaSnapshot: Codable, Equatable, Sendable {
  public let weekly: GeminiQuotaWindow?
  public let fiveHour: GeminiQuotaWindow?
  public let fetchedAt: Date

  public init(weekly: GeminiQuotaWindow?, fiveHour: GeminiQuotaWindow?, fetchedAt: Date) {
    self.weekly = weekly
    self.fiveHour = fiveHour
    self.fetchedAt = fetchedAt
  }

  public func isStale(relativeTo now: Date = Date()) -> Bool {
    let age = now.timeIntervalSince(fetchedAt)
    return age < -5 || age > 150
  }
}

public struct AntigravityQuotaClient: Sendable {
  private struct Hub: Decodable {
    let pid: Int32
    let httpPort: Int
    let csrfToken: String
  }

  private struct Summary: Decodable {
    struct Payload: Decodable {
      let groups: [Group]?
    }
    struct Group: Decodable {
      let displayName: String?
      let buckets: [Bucket]

      private enum CodingKeys: String, CodingKey {
        case displayName, name, buckets
      }

      init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        displayName =
          try fields.decodeIfPresent(String.self, forKey: .displayName)
          ?? fields.decodeIfPresent(String.self, forKey: .name)
        buckets = try fields.decode([Bucket].self, forKey: .buckets)
      }
    }
    struct Bucket: Decodable {
      let bucketId: String?
      let window: String?
      let remainingFraction: Double?
      let resetTime: String?

      private enum CodingKeys: String, CodingKey {
        case bucketId, id, window, remainingFraction, resetTime
      }

      init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        bucketId =
          try fields.decodeIfPresent(String.self, forKey: .bucketId)
          ?? fields.decodeIfPresent(String.self, forKey: .id)
        window = try fields.decodeIfPresent(String.self, forKey: .window)
        remainingFraction = try fields.decodeIfPresent(Double.self, forKey: .remainingFraction)
        resetTime = try fields.decodeIfPresent(String.self, forKey: .resetTime)
      }
    }
    let response: Payload?
    let groups: [Group]?
  }

  private struct CLIResult: Decodable {
    struct Command: Decodable {
      let name: String
      let data: Summary.Payload
    }
    let status: String
    let numTurns: Int
    let command: Command
  }

  public enum Failure: Error {
    case noLocalHub, unreadableQuota
  }

  private final class LoopbackSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
      _ session: URLSession,
      task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse,
      newRequest request: URLRequest,
      completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
      completionHandler(nil)
    }
  }

  private static let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = [:]
    configuration.httpShouldSetCookies = false
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 5
    configuration.timeoutIntervalForResource = 6
    return URLSession(
      configuration: configuration, delegate: LoopbackSessionDelegate(), delegateQueue: nil)
  }()

  public init() {}

  public func fetch(antigravityBundle: URL) async throws -> GeminiQuotaSnapshot {
    let directory = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".gemini/antigravity/daemon", isDirectory: true)
    let files =
      (try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey],
        options: [.skipsHiddenFiles]
      )) ?? []
    let executableDirectory = antigravityBundle.resolvingSymlinksInPath().path + "/Contents/"
    let hubs = files.compactMap { file -> (Hub, Date)? in
      guard
        file.lastPathComponent.range(of: #"^hub_[0-9]+\.json$"#, options: .regularExpression)
          != nil,
        let attributes = try? file.resourceValues(forKeys: [
          .contentModificationDateKey, .isRegularFileKey, .fileSizeKey,
        ]),
        attributes.isRegularFile == true,
        let bytes = attributes.fileSize, bytes <= 16_384,
        let data = try? Data(contentsOf: file),
        let hub = try? JSONDecoder().decode(Hub.self, from: data),
        (1...65535).contains(hub.httpPort),
        file.lastPathComponent == "hub_\(hub.httpPort).json",
        hub.pid > 0, !hub.csrfToken.isEmpty,
        hub.csrfToken.unicodeScalars.allSatisfy({ (33...126).contains($0.value) })
      else { return nil }

      var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
      guard proc_pidpath(hub.pid, &path, UInt32(path.count)) > 0,
        String(cString: path).hasPrefix(executableDirectory)
      else { return nil }
      return (hub, attributes.contentModificationDate ?? .distantPast)
    }.sorted { $0.1 > $1.1 }

    guard !hubs.isEmpty else { throw Failure.noLocalHub }
    for (hub, _) in hubs {
      try Task.checkCancellation()
      if let quota = try? await read(hub) {
        return quota
      }
    }
    throw Failure.unreadableQuota
  }

  public func fetchFromCLI(executable: URL) async throws -> GeminiQuotaSnapshot {
    try await Task.detached(priority: .utility) {
      let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-monitor-agy-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
      defer { try? FileManager.default.removeItem(at: scratch) }

      let versionData = try Self.runCLI(
        executable, arguments: ["--version"], directory: scratch, output: "version.txt", timeout: 5
      )
      let version = String(decoding: versionData, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let components = version.split(separator: ".").prefix(3).compactMap { part in
        Int(part.prefix(while: \.isASCII).prefix(while: \.isNumber))
      }
      // Older versions could send an unrecognized slash command to an agent.
      guard components.count == 3, !components.lexicographicallyPrecedes([1, 1, 11])
      else { throw Failure.unreadableQuota }

      let data = try Self.runCLI(
        executable,
        arguments: [
          "-p", "/usage", "--output-format", "json", "--print-timeout", "16s",
          "--log-file", scratch.appendingPathComponent("agy.log").path,
        ], directory: scratch, output: "usage.json", timeout: 23)
      return try Self.decodeCLI(data)
    }.value
  }

  private static func runCLI(
    _ executable: URL,
    arguments: [String],
    directory: URL,
    output: String,
    timeout: TimeInterval
  ) throws -> Data {
    let outputURL = directory.appendingPathComponent(output)
    guard FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    else { throw Failure.unreadableQuota }
    let outputHandle = try FileHandle(forWritingTo: outputURL)
    defer { try? outputHandle.close() }

    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.environment = ProcessInfo.processInfo.environment.merging(
      ["NO_COLOR": "1", "TERM": "dumb"]
    ) { _, value in value }
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = outputHandle
    process.standardError = FileHandle.nullDevice
    try process.run()
    let deadline = DispatchWorkItem {
      guard process.isRunning else { return }
      process.terminate()
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      }
    }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
    process.waitUntilExit()
    deadline.cancel()

    let size = try outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard process.terminationStatus == 0, (1...65_536).contains(size)
    else { throw Failure.unreadableQuota }
    return try Data(contentsOf: outputURL)
  }

  private func read(_ hub: Hub) async throws -> GeminiQuotaSnapshot {
    let url = URL(
      string:
        "http://127.0.0.1:\(hub.httpPort)/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
    )!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
    request.setValue(hub.csrfToken, forHTTPHeaderField: "x-codeium-csrf-token")
    request.httpBody = Data(
      #"{"metadata":{"ideName":"antigravity","extensionName":"antigravity"}}"#.utf8)
    let (data, response) = try await Self.session.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 256_000
    else { throw Failure.unreadableQuota }
    return try Self.decode(data)
  }

  public static func decode(_ data: Data, fetchedAt: Date = Date()) throws -> GeminiQuotaSnapshot {
    let summary = try JSONDecoder().decode(Summary.self, from: data)
    return try quota(from: summary.response?.groups ?? summary.groups ?? [], fetchedAt: fetchedAt)
  }

  public static func decodeCLI(_ data: Data, fetchedAt: Date = Date()) throws -> GeminiQuotaSnapshot
  {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let result = try decoder.decode(CLIResult.self, from: data)
    guard result.status == "SUCCESS", result.numTurns == 0, result.command.name == "usage"
    else { throw Failure.unreadableQuota }
    return try quota(from: result.command.data.groups ?? [], fetchedAt: fetchedAt)
  }

  private static func quota(from groups: [Summary.Group], fetchedAt: Date) throws
    -> GeminiQuotaSnapshot
  {
    guard
      let group = groups.first(where: { group in
        group.buckets.contains { $0.bucketId == "gemini-weekly" || $0.bucketId == "gemini-5h" }
      })
        ?? groups.first(where: {
          $0.displayName?.caseInsensitiveCompare("Gemini Models") == .orderedSame
        })
    else { throw Failure.unreadableQuota }

    let weekly =
      group.buckets.first { $0.bucketId == "gemini-weekly" }
      ?? group.buckets.first { $0.window?.lowercased() == "weekly" }
    let fiveHour =
      group.buckets.first { $0.bucketId == "gemini-5h" }
      ?? group.buckets.first { $0.window?.lowercased() == "5h" }
    let quota = GeminiQuotaSnapshot(
      weekly: reading(weekly), fiveHour: reading(fiveHour), fetchedAt: fetchedAt)
    guard quota.weekly != nil || quota.fiveHour != nil else { throw Failure.unreadableQuota }
    return quota
  }

  private static func reading(_ bucket: Summary.Bucket?) -> GeminiQuotaWindow? {
    guard let bucket else { return nil }
    let resetTime = bucket.resetTime?.trimmingCharacters(in: .whitespacesAndNewlines)
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = resetTime.flatMap {
      fractional.date(from: $0) ?? ISO8601DateFormatter().date(from: $0)
    }
    let reset = date.flatMap { $0.timeIntervalSince1970 > 0 ? $0 : nil }
    if let remaining = bucket.remainingFraction {
      guard (0...1).contains(remaining) else { return nil }
      return GeminiQuotaWindow(remainingPercent: remaining * 100, resetsAt: reset)
    }
    // The protobuf response omits zero fractions. A reset is set for
    // exhausted windows and omitted or zero-epoch for untouched windows.
    if reset != nil {
      return GeminiQuotaWindow(remainingPercent: 0, resetsAt: reset)
    }
    if resetTime == nil || resetTime == "" || date == Date(timeIntervalSince1970: 0) {
      return GeminiQuotaWindow(remainingPercent: 100, resetsAt: nil)
    }
    return nil
  }
}
