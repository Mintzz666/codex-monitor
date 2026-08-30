@preconcurrency import CoreBluetooth
import Foundation

public struct NRFEPDDeviceInformation: Equatable, Sendable {
  public let device: EPDDeviceDescriptor
  public let firmwareVersion: UInt8?
  public let driverID: UInt8?
  public let pinConfiguration: Data?
  public let reportedMTU: Int?
  public let supportsRLE: Bool

  public init(
    device: EPDDeviceDescriptor,
    firmwareVersion: UInt8? = nil,
    driverID: UInt8? = nil,
    pinConfiguration: Data? = nil,
    reportedMTU: Int? = nil,
    supportsRLE: Bool = false
  ) {
    self.device = device
    self.firmwareVersion = firmwareVersion
    self.driverID = driverID
    self.pinConfiguration = pinConfiguration
    self.reportedMTU = reportedMTU
    self.supportsRLE = supportsRLE
  }

  public var driverDescription: String {
    switch driverID {
    case 0x01: return "UC8176 · 4.2-inch black/white"
    case 0x02: return "SSD1619 · 4.2-inch black/white/red"
    case 0x03: return "UC8176 · 4.2-inch black/white/red"
    case 0x04: return "SSD1619 · 4.2-inch black/white"
    case 0x05: return "JD79668 · 4.2-inch four-color"
    case .some(let value):
      return String(format: "Unknown driver · 0x%02X", value)
    case nil: return "Waiting for driver information"
    }
  }

  public var isStandardThreeColorDisplay: Bool {
    driverID == 0x02 || driverID == 0x03
  }
}

public enum NRFEPDBluetoothError: Error, Equatable, LocalizedError, Sendable {
  case bluetoothUnavailable(String)
  case noCompatibleDevice
  case multipleCompatibleDevices([String])
  case deviceUnavailable
  case connectionFailed(String)
  case serviceUnavailable
  case characteristicUnavailable
  case informationTimeout
  case unsupportedDisplay(String)
  case notConnected
  case writeFailed(String)

  public var errorDescription: String? {
    switch self {
    case .bluetoothUnavailable(let reason):
      return "Bluetooth is unavailable: \(reason)"
    case .noCompatibleDevice:
      return "No NRF_EPD device was found"
    case .multipleCompatibleDevices(let names):
      return "Multiple NRF_EPD devices were found: \(names.joined(separator: ", "))"
    case .deviceUnavailable:
      return "The selected NRF_EPD device is no longer available"
    case .connectionFailed(let message):
      return "NRF_EPD connection failed: \(message)"
    case .serviceUnavailable:
      return "The NRF_EPD service was not found"
    case .characteristicUnavailable:
      return "The NRF_EPD data characteristic was not found"
    case .informationTimeout:
      return "Timed out while reading NRF_EPD device information"
    case .unsupportedDisplay(let description):
      return "Unsupported NRF_EPD display: \(description)"
    case .notConnected:
      return "The NRF_EPD display is not connected"
    case .writeFailed(let message):
      return "NRF_EPD write failed: \(message)"
    }
  }
}

@MainActor
public final class NRFEPDBluetoothTransport: NSObject, EPDTransport {
  private static let serviceUUID = CBUUID(
    string: NRFEPDProtocol.serviceUUID
  )
  private static let dataUUID = CBUUID(
    string: NRFEPDProtocol.dataCharacteristicUUID
  )
  private static let versionUUID = CBUUID(
    string: NRFEPDProtocol.versionCharacteristicUUID
  )

  public var informationDidChange: ((NRFEPDDeviceInformation) -> Void)?
  public var stateDidChange: ((EPDTransportState) -> Void)?

  private var centralManager: CBCentralManager!
  private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
  private var discoveredDescriptors: [UUID: EPDDeviceDescriptor] = [:]
  private var connectedPeripheral: CBPeripheral?
  private var dataCharacteristic: CBCharacteristic?
  private var versionCharacteristic: CBCharacteristic?
  private var connectContinuation: CheckedContinuation<Void, Error>?
  private var connectTimeoutTask: Task<Void, Never>?
  private var writeContinuation: CheckedContinuation<Void, Error>?
  private var currentInformation: NRFEPDDeviceInformation?
  private var transportState: EPDTransportState = .idle {
    didSet { stateDidChange?(transportState) }
  }

  public override init() {
    super.init()
    centralManager = CBCentralManager(delegate: self, queue: .main)
  }

  public func currentState() async -> EPDTransportState {
    transportState
  }

  public func scan() async throws -> [EPDDeviceDescriptor] {
    try await waitForBluetooth()
    discoveredPeripherals.removeAll()
    discoveredDescriptors.removeAll()
    transportState = .scanning

    centralManager.scanForPeripherals(
      withServices: nil,
      options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
    )
    try await Task.sleep(nanoseconds: 5_000_000_000)
    centralManager.stopScan()

    if case .scanning = transportState {
      transportState = .idle
    }
    return discoveredDescriptors.values.sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }

  public func connect(to device: EPDDeviceDescriptor) async throws {
    try await waitForBluetooth()
    guard let identifier = UUID(uuidString: device.id) else {
      throw NRFEPDBluetoothError.deviceUnavailable
    }
    let peripheral =
      discoveredPeripherals[identifier]
      ?? centralManager.retrievePeripherals(withIdentifiers: [identifier]).first
    guard let peripheral else {
      throw NRFEPDBluetoothError.deviceUnavailable
    }
    discoveredPeripherals[identifier] = peripheral
    discoveredDescriptors[identifier] = device

    if let connectedPeripheral, connectedPeripheral != peripheral {
      centralManager.cancelPeripheralConnection(connectedPeripheral)
    }

    currentInformation = NRFEPDDeviceInformation(device: device)
    connectedPeripheral = peripheral
    peripheral.delegate = self
    transportState = .connecting(deviceID: device.id)

    try await withCheckedThrowingContinuation { continuation in
      connectContinuation = continuation
      centralManager.connect(peripheral)
      connectTimeoutTask?.cancel()
      connectTimeoutTask = Task { [weak self, weak peripheral] in
        do {
          try await Task.sleep(nanoseconds: 12_000_000_000)
        } catch {
          return
        }
        guard let self, self.connectContinuation != nil else { return }
        if let peripheral {
          self.centralManager.cancelPeripheralConnection(peripheral)
        }
        self.transportState = .failed(message: "connection timed out")
        self.finishConnection(
          with: NRFEPDBluetoothError.connectionFailed("timed out")
        )
      }
    }
  }

  public func waitForInformation(
    timeoutNanoseconds: UInt64 = 5_000_000_000
  ) async throws -> NRFEPDDeviceInformation {
    let deadline = ContinuousClock.now.advanced(
      by: .nanoseconds(Int64(timeoutNanoseconds))
    )
    while ContinuousClock.now < deadline {
      if let information = currentInformation,
        information.driverID != nil
      {
        return information
      }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    throw NRFEPDBluetoothError.informationTimeout
  }

  public func send(frame: EPDFrame) async throws {
    guard let peripheral = connectedPeripheral,
      peripheral.state == .connected,
      dataCharacteristic != nil
    else {
      throw NRFEPDBluetoothError.notConnected
    }

    let deviceID = peripheral.identifier.uuidString
    let supportsWriteWithoutResponse =
      dataCharacteristic?.properties.contains(.writeWithoutResponse) == true
    let imageWriteType: CBCharacteristicWriteType =
      supportsWriteWithoutResponse ? .withoutResponse : .withResponse
    let maximumLength = max(
      3,
      min(
        currentInformation?.reportedMTU ?? 20,
        peripheral.maximumWriteValueLength(for: imageWriteType)
      )
    )
    // The vendor controller linked from the device manual keeps using the
    // legacy plane headers unless the device explicitly reports RLE support.
    let usesModernHeader = currentInformation?.supportsRLE == true
    let blackPackets = try NRFEPDProtocol.imagePackets(
      plane: frame.blackPlane,
      color: .black,
      maximumWriteValueLength: maximumLength,
      usesModernHeader: usesModernHeader
    )
    let redPackets = try NRFEPDProtocol.imagePackets(
      plane: frame.redPlane,
      color: .red,
      maximumWriteValueLength: maximumLength,
      usesModernHeader: usesModernHeader
    )
    let totalBytes =
      blackPackets.reduce(0) { $0 + $1.count }
      + redPackets.reduce(0) { $0 + $1.count }
    var completedBytes = 0

    try await writeWithResponse(Data([NRFEPDProtocol.initializeCommand]))
    try await Task.sleep(nanoseconds: 50_000_000)
    for packets in [blackPackets, redPackets] {
      for (packetIndex, packet) in packets.enumerated() {
        try Task.checkCancellation()
        if supportsWriteWithoutResponse,
          !NRFEPDProtocol.shouldRequestWriteResponse(
            packetIndex: packetIndex
          )
        {
          try await writeWithoutResponse(packet)
        } else {
          try await writeWithResponse(packet)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        completedBytes += packet.count
        transportState = .transferring(
          completedBytes: completedBytes,
          totalBytes: totalBytes
        )
      }
    }
    try await writeWithResponse(Data([NRFEPDProtocol.refreshCommand]))
    try await Task.sleep(nanoseconds: 50_000_000)
    transportState = .connected(deviceID: deviceID)
  }

  public func disconnect() async {
    if let connectedPeripheral {
      centralManager.cancelPeripheralConnection(connectedPeripheral)
    }
    finishConnection(with: NRFEPDBluetoothError.notConnected)
    finishWrite(with: NRFEPDBluetoothError.notConnected)
    connectedPeripheral = nil
    dataCharacteristic = nil
    versionCharacteristic = nil
    currentInformation = nil
    transportState = .idle
  }

  private func waitForBluetooth() async throws {
    for _ in 0..<40 {
      switch centralManager.state {
      case .poweredOn:
        return
      case .unsupported:
        throw NRFEPDBluetoothError.bluetoothUnavailable("unsupported")
      case .unauthorized:
        throw NRFEPDBluetoothError.bluetoothUnavailable("permission denied")
      case .poweredOff:
        throw NRFEPDBluetoothError.bluetoothUnavailable("powered off")
      case .resetting, .unknown:
        try await Task.sleep(nanoseconds: 100_000_000)
      @unknown default:
        throw NRFEPDBluetoothError.bluetoothUnavailable("unknown state")
      }
    }
    throw NRFEPDBluetoothError.bluetoothUnavailable("initialization timeout")
  }

  private func writeWithResponse(_ value: Data) async throws {
    guard let characteristic = dataCharacteristic,
      let peripheral = connectedPeripheral,
      peripheral.state == .connected
    else {
      throw NRFEPDBluetoothError.notConnected
    }

    try await withCheckedThrowingContinuation { continuation in
      writeContinuation = continuation
      peripheral.writeValue(value, for: characteristic, type: .withResponse)
    }
  }

  private func writeWithoutResponse(_ value: Data) async throws {
    guard let characteristic = dataCharacteristic,
      let peripheral = connectedPeripheral,
      peripheral.state == .connected
    else {
      throw NRFEPDBluetoothError.notConnected
    }

    while !peripheral.canSendWriteWithoutResponse {
      try Task.checkCancellation()
      guard peripheral.state == .connected else {
        throw NRFEPDBluetoothError.notConnected
      }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    peripheral.writeValue(value, for: characteristic, type: .withoutResponse)
  }

  private func updateInformation(
    firmwareVersion: UInt8? = nil,
    driverID: UInt8? = nil,
    pinConfiguration: Data? = nil,
    reportedMTU: Int? = nil,
    supportsRLE: Bool? = nil
  ) {
    guard let existing = currentInformation else { return }
    let updated = NRFEPDDeviceInformation(
      device: existing.device,
      firmwareVersion: firmwareVersion ?? existing.firmwareVersion,
      driverID: driverID ?? existing.driverID,
      pinConfiguration: pinConfiguration ?? existing.pinConfiguration,
      reportedMTU: reportedMTU ?? existing.reportedMTU,
      supportsRLE: supportsRLE ?? existing.supportsRLE
    )
    currentInformation = updated
    informationDidChange?(updated)
  }

  private func finishConnection(with error: Error? = nil) {
    guard let continuation = connectContinuation else { return }
    connectContinuation = nil
    connectTimeoutTask?.cancel()
    connectTimeoutTask = nil
    if let error {
      continuation.resume(throwing: error)
    } else {
      continuation.resume()
    }
  }

  private func finishWrite(with error: Error? = nil) {
    guard let continuation = writeContinuation else { return }
    writeContinuation = nil
    if let error {
      continuation.resume(throwing: error)
    } else {
      continuation.resume()
    }
  }

}

extension NRFEPDBluetoothTransport: @preconcurrency CBCentralManagerDelegate {
  public func centralManagerDidUpdateState(_ central: CBCentralManager) {}

  public func centralManager(
    _ central: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi: NSNumber
  ) {
    let advertisedName =
      advertisementData[CBAdvertisementDataLocalNameKey]
      as? String
    let name = advertisedName ?? peripheral.name ?? "Unknown BLE device"
    let normalizedName = name.uppercased()
    guard normalizedName.contains("NRF_EPD") || normalizedName.hasPrefix("EPD_")
    else { return }

    discoveredPeripherals[peripheral.identifier] = peripheral
    discoveredDescriptors[peripheral.identifier] = EPDDeviceDescriptor(
      id: peripheral.identifier.uuidString,
      name: name,
      signalStrength: rssi.intValue
    )
  }

  public func centralManager(
    _ central: CBCentralManager,
    didConnect peripheral: CBPeripheral
  ) {
    peripheral.discoverServices([Self.serviceUUID])
  }

  public func centralManager(
    _ central: CBCentralManager,
    didFailToConnect peripheral: CBPeripheral,
    error: Error?
  ) {
    let message = error?.localizedDescription ?? "unknown error"
    transportState = .failed(message: message)
    finishConnection(
      with: NRFEPDBluetoothError.connectionFailed(message)
    )
  }

  public func centralManager(
    _ central: CBCentralManager,
    didDisconnectPeripheral peripheral: CBPeripheral,
    error: Error?
  ) {
    dataCharacteristic = nil
    versionCharacteristic = nil
    let message = error?.localizedDescription ?? "device disconnected"
    if error != nil {
      transportState = .failed(message: message)
    } else {
      transportState = .idle
    }
    finishConnection(
      with: NRFEPDBluetoothError.connectionFailed(message)
    )
    finishWrite(with: NRFEPDBluetoothError.writeFailed(message))
  }
}

extension NRFEPDBluetoothTransport: @preconcurrency CBPeripheralDelegate {
  public func peripheral(
    _ peripheral: CBPeripheral,
    didDiscoverServices error: Error?
  ) {
    if let error {
      finishConnection(
        with: NRFEPDBluetoothError.connectionFailed(
          error.localizedDescription
        )
      )
      return
    }
    guard
      let service = peripheral.services?.first(where: {
        $0.uuid == Self.serviceUUID
      })
    else {
      finishConnection(with: NRFEPDBluetoothError.serviceUnavailable)
      return
    }
    peripheral.discoverCharacteristics(
      [Self.dataUUID, Self.versionUUID],
      for: service
    )
  }

  public func peripheral(
    _ peripheral: CBPeripheral,
    didDiscoverCharacteristicsFor service: CBService,
    error: Error?
  ) {
    if let error {
      finishConnection(
        with: NRFEPDBluetoothError.connectionFailed(
          error.localizedDescription
        )
      )
      return
    }

    dataCharacteristic = service.characteristics?.first(where: {
      $0.uuid == Self.dataUUID
    })
    versionCharacteristic = service.characteristics?.first(where: {
      $0.uuid == Self.versionUUID
    })
    guard let dataCharacteristic else {
      finishConnection(with: NRFEPDBluetoothError.characteristicUnavailable)
      return
    }

    if let versionCharacteristic {
      peripheral.readValue(for: versionCharacteristic)
    }
    peripheral.setNotifyValue(true, for: dataCharacteristic)
  }

  public func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateNotificationStateFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    if let error {
      finishConnection(
        with: NRFEPDBluetoothError.connectionFailed(
          error.localizedDescription
        )
      )
      return
    }
    guard characteristic.uuid == Self.dataUUID,
      characteristic.isNotifying
    else { return }

    transportState = .connected(deviceID: peripheral.identifier.uuidString)
    finishConnection()
    peripheral.writeValue(
      Data([NRFEPDProtocol.initializeCommand]),
      for: characteristic,
      type: .withResponse
    )
  }

  public func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    guard error == nil, let value = characteristic.value else { return }

    if characteristic.uuid == Self.versionUUID {
      updateInformation(firmwareVersion: value.first)
      return
    }
    guard characteristic.uuid == Self.dataUUID else { return }

    if currentInformation?.driverID == nil, value.count >= 8 {
      updateInformation(
        driverID: value[7],
        pinConfiguration: Data(value.prefix(7))
      )
      return
    }

    guard let message = String(data: value, encoding: .utf8) else { return }
    let mtu = Self.integer(after: "mtu=", in: message)
    let supportsRLE = message.contains("rle=1")
    if mtu != nil || message.contains("rle=") {
      updateInformation(
        reportedMTU: mtu,
        supportsRLE: supportsRLE
      )
    }
  }

  public func peripheral(
    _ peripheral: CBPeripheral,
    didWriteValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    if let error {
      finishWrite(
        with: NRFEPDBluetoothError.writeFailed(
          error.localizedDescription
        )
      )
    } else {
      finishWrite()
    }
  }

  private static func integer(after marker: String, in text: String) -> Int? {
    guard let range = text.range(of: marker) else { return nil }
    let suffix = text[range.upperBound...]
    let digits = suffix.prefix(while: { $0.isNumber })
    return Int(digits)
  }
}
