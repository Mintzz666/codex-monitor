import CryptoKit
import Foundation

/// A firmware-neutral frame for a black/white/red electronic-paper display.
/// Concrete Bluetooth adapters decide how these planes are packetized.
public struct EPDFrame: Equatable, Sendable {
  public static let standardWidth = 400
  public static let standardHeight = 300
  public static let standardPlaneByteCount = 15_000

  public let width: Int
  public let height: Int
  public let blackPlane: Data
  public let redPlane: Data

  public init(
    width: Int = standardWidth,
    height: Int = standardHeight,
    blackPlane: Data,
    redPlane: Data
  ) throws {
    guard width > 0, height > 0, width.isMultiple(of: 8) else {
      throw EPDFrameValidationError.invalidDimensions(width: width, height: height)
    }
    let expectedByteCount = width * height / 8
    guard
      blackPlane.count == expectedByteCount,
      redPlane.count == expectedByteCount
    else {
      throw EPDFrameValidationError.invalidPlaneByteCount(
        expected: expectedByteCount,
        black: blackPlane.count,
        red: redPlane.count
      )
    }

    self.width = width
    self.height = height
    self.blackPlane = blackPlane
    self.redPlane = redPlane
  }
}

public enum EPDFrameValidationError: Error, Equatable, LocalizedError, Sendable {
  case invalidDimensions(width: Int, height: Int)
  case invalidPlaneByteCount(expected: Int, black: Int, red: Int)

  public var errorDescription: String? {
    switch self {
    case .invalidDimensions(let width, let height):
      return "Unsupported EPD dimensions: \(width)×\(height)"
    case .invalidPlaneByteCount(let expected, let black, let red):
      return "Invalid EPD planes: expected \(expected) bytes, black=\(black), red=\(red)"
    }
  }
}

public struct EPDDeviceDescriptor: Equatable, Sendable, Identifiable {
  public let id: String
  public let name: String
  public let signalStrength: Int?

  public init(id: String, name: String, signalStrength: Int? = nil) {
    self.id = id
    self.name = name
    self.signalStrength = signalStrength
  }
}

public enum EPDTransportState: Equatable, Sendable {
  case idle
  case scanning
  case connecting(deviceID: String)
  case connected(deviceID: String)
  case transferring(completedBytes: Int, totalBytes: Int)
  case failed(message: String)
}

/// Boundary reserved for the physical display. No GATT UUID, packet framing,
/// clear/init sequence, or firmware behavior is assumed at this stage.
@MainActor
public protocol EPDTransport: Sendable {
  func currentState() async -> EPDTransportState
  func scan() async throws -> [EPDDeviceDescriptor]
  func connect(to device: EPDDeviceDescriptor) async throws
  func send(frame: EPDFrame) async throws
  func disconnect() async
}

public enum NRFEPDColorPlane: Sendable {
  case black
  case red
}

public enum NRFEPDProtocol {
  public static let serviceUUID = "62750001-D828-918D-FB46-B6C11C675AEC"
  public static let dataCharacteristicUUID =
    "62750002-D828-918D-FB46-B6C11C675AEC"
  public static let versionCharacteristicUUID =
    "62750003-D828-918D-FB46-B6C11C675AEC"

  public static let initializeCommand: UInt8 = 0x01
  public static let clearCommand: UInt8 = 0x02
  public static let refreshCommand: UInt8 = 0x05
  public static let sleepCommand: UInt8 = 0x06
  public static let writeImageCommand: UInt8 = 0x30
  public static let writesWithoutResponseBeforeAcknowledgement = 50

  public static func shouldRequestWriteResponse(packetIndex: Int) -> Bool {
    (packetIndex + 1).isMultiple(
      of: writesWithoutResponseBeforeAcknowledgement + 1
    )
  }

  /// Builds complete characteristic values, including the WRITE_IMG command
  /// byte and the firmware's per-chunk control byte.
  public static func imagePackets(
    plane: Data,
    color: NRFEPDColorPlane,
    maximumWriteValueLength: Int,
    usesModernHeader: Bool
  ) throws -> [Data] {
    guard maximumWriteValueLength > 2 else {
      throw NRFEPDProtocolError.invalidMaximumWriteValueLength(
        maximumWriteValueLength
      )
    }

    let chunkSize = maximumWriteValueLength - 2
    var packets: [Data] = []
    packets.reserveCapacity((plane.count + chunkSize - 1) / chunkSize)

    var offset = 0
    while offset < plane.count {
      let end = min(offset + chunkSize, plane.count)
      let isFirst = offset == 0
      let control: UInt8

      if usesModernHeader {
        let planeBit: UInt8 = color == .black ? 0x00 : 0x01
        control = planeBit | (isFirst ? 0x02 : 0x00)
      } else {
        let base: UInt8 = color == .black ? 0x0F : 0x00
        control = base | (isFirst ? 0x00 : 0xF0)
      }

      var packet = Data([writeImageCommand, control])
      packet.append(plane[offset..<end])
      packets.append(packet)
      offset = end
    }

    return packets
  }
}

public enum NRFEPDProtocolError: Error, Equatable, LocalizedError, Sendable {
  case invalidMaximumWriteValueLength(Int)

  public var errorDescription: String? {
    switch self {
    case .invalidMaximumWriteValueLength(let length):
      return "Invalid NRF_EPD maximum write length: \(length)"
    }
  }
}

/// Pure scheduling and deduplication rules for the low-power EPD workflow.
public enum EPDSyncPolicy {
  public static let automaticInterval: TimeInterval = 60 * 60

  public static func automaticSyncIsDue(
    now: Date,
    lastCheckAt: Date?,
    timeZone: TimeZone = .current
  ) -> Bool {
    guard let lastCheckAt else { return true }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    if !calendar.isDate(now, inSameDayAs: lastCheckAt) {
      return true
    }
    return now.timeIntervalSince(lastCheckAt) >= automaticInterval
  }

  /// Hashes the rendered screen while normalizing the volatile footer time.
  /// This means an hourly check does not wake the display merely to change
  /// "updated at", while a date, quota, reset, or token-series change does.
  public static func contentFingerprint(
    _ content: EPDLiveContent
  ) throws -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = content.timeZone
    let normalized = EPDLiveContent(
      now: content.now,
      updatedAt: calendar.startOfDay(for: content.now),
      remainingPercent: content.remainingPercent,
      resetsAt: content.resetsAt,
      lifetimeTokens: content.lifetimeTokens,
      dailyTokenUsage: content.dailyTokenUsage,
      timeZone: content.timeZone
    )
    return frameFingerprint(try EPDLiveFrameRenderer.render(normalized))
  }

  public static func frameFingerprint(_ frame: EPDFrame) -> String {
    var bytes = Data()
    bytes.reserveCapacity(frame.blackPlane.count + frame.redPlane.count + 8)
    withUnsafeBytes(of: UInt32(frame.width).bigEndian) {
      bytes.append(contentsOf: $0)
    }
    withUnsafeBytes(of: UInt32(frame.height).bigEndian) {
      bytes.append(contentsOf: $0)
    }
    bytes.append(frame.blackPlane)
    bytes.append(frame.redPlane)
    return SHA256.hash(data: bytes).map {
      String(format: "%02x", $0)
    }.joined()
  }
}
