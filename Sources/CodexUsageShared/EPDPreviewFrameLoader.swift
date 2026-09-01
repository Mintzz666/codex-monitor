import CoreGraphics
import CoreText
import Foundation
import ImageIO

public enum EPDPreviewFrameLoader {
  public static func load(from url: URL) throws -> EPDFrame {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
      throw EPDPreviewFrameError.cannotDecodeImage
    }
    return try load(image: image)
  }

  public static func load(image: CGImage) throws -> EPDFrame {
    guard image.width == EPDFrame.standardWidth,
      image.height == EPDFrame.standardHeight
    else {
      throw EPDPreviewFrameError.invalidDimensions(
        width: image.width,
        height: image.height
      )
    }

    let width = image.width
    let height = image.height
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
    guard
      let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          | CGBitmapInfo.byteOrder32Big.rawValue
      )
    else {
      throw EPDPreviewFrameError.cannotCreateBitmap
    }

    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    var blackPlane = Data(
      repeating: 0xFF,
      count: EPDFrame.standardPlaneByteCount
    )
    var redPlane = Data(
      repeating: 0xFF,
      count: EPDFrame.standardPlaneByteCount
    )

    for y in 0..<height {
      for x in 0..<width {
        let source = verticallyFlippedSourceCoordinate(
          x: x,
          y: y,
          width: width,
          height: height
        )
        let pixelOffset = source.y * bytesPerRow + source.x * 4
        let red = Int(pixels[pixelOffset])
        let green = Int(pixels[pixelOffset + 1])
        let blue = Int(pixels[pixelOffset + 2])
        let isRed = red - green > 18 && red - blue > 18
        let luminance = red * 2126 + green * 7152 + blue * 722
        let isBlack = !isRed && luminance < 1_800_000
        guard isBlack || isRed else { continue }

        let byteIndex = y * (width / 8) + x / 8
        let mask = UInt8(1 << (7 - (x % 8)))
        if isRed {
          redPlane[byteIndex] &= ~mask
        } else {
          blackPlane[byteIndex] &= ~mask
        }
      }
    }

    return try EPDFrame(
      blackPlane: blackPlane,
      redPlane: redPlane
    )
  }

  public static func verticallyFlippedSourceCoordinate(
    x: Int,
    y: Int,
    width: Int,
    height: Int
  ) -> (x: Int, y: Int) {
    (x, height - 1 - y)
  }
}

public struct EPDLiveContent: Equatable, Sendable {
  public let now: Date
  public let updatedAt: Date
  public let remainingPercent: Double
  public let resetsAt: Date?
  public let lifetimeTokens: Int64?
  public let dailyTokenUsage: [SharedDailyTokenUsage]
  public let timeZone: TimeZone

  public init(
    now: Date,
    updatedAt: Date,
    remainingPercent: Double,
    resetsAt: Date?,
    lifetimeTokens: Int64?,
    dailyTokenUsage: [SharedDailyTokenUsage],
    timeZone: TimeZone = .current
  ) {
    self.now = now
    self.updatedAt = updatedAt
    self.remainingPercent = min(100, max(0, remainingPercent))
    self.resetsAt = resetsAt
    self.lifetimeTokens = lifetimeTokens
    self.dailyTokenUsage = dailyTokenUsage
    self.timeZone = timeZone
  }
}

public enum EPDLiveFrameRenderer {
  private static let width = EPDFrame.standardWidth
  private static let height = EPDFrame.standardHeight
  private static let black = CGColor(
    red: 0.03,
    green: 0.03,
    blue: 0.03,
    alpha: 1
  )
  private static let red = CGColor(
    red: 0.82,
    green: 0,
    blue: 0,
    alpha: 1
  )
  private static let white = CGColor(
    red: 1,
    green: 1,
    blue: 1,
    alpha: 1
  )

  public static func render(_ content: EPDLiveContent) throws -> EPDFrame {
    try EPDPreviewFrameLoader.load(image: makeImage(content))
  }

  public static func writePNG(
    _ content: EPDLiveContent,
    to url: URL
  ) throws {
    let image = try previewImage(from: render(content))
    guard
      let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        "public.png" as CFString,
        1,
        nil
      )
    else {
      throw EPDLiveFrameError.cannotEncodePreview
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw EPDLiveFrameError.cannotEncodePreview
    }
  }

  private static func previewImage(from frame: EPDFrame) throws -> CGImage {
    var pixels = [UInt8](repeating: 255, count: frame.width * frame.height * 4)
    for y in 0..<frame.height {
      let panelY = y
      for x in 0..<frame.width {
        let byteIndex = panelY * (frame.width / 8) + x / 8
        let mask = UInt8(1 << (7 - (x % 8)))
        let isRed = frame.redPlane[byteIndex] & mask == 0
        let isBlack = frame.blackPlane[byteIndex] & mask == 0
        let offset = (y * frame.width + x) * 4
        if isRed {
          pixels[offset] = 190
          pixels[offset + 1] = 38
          pixels[offset + 2] = 35
        } else if isBlack {
          pixels[offset] = 18
          pixels[offset + 1] = 18
          pixels[offset + 2] = 18
        }
        pixels[offset + 3] = 255
      }
    }

    let data = Data(pixels) as CFData
    guard let provider = CGDataProvider(data: data) else {
      throw EPDLiveFrameError.cannotCreateBitmap
    }
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
      CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    )
    guard
      let image = CGImage(
        width: frame.width,
        height: frame.height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: frame.width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: bitmapInfo,
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
      )
    else {
      throw EPDLiveFrameError.cannotCreateBitmap
    }
    return image
  }

  private static func makeImage(_ content: EPDLiveContent) throws -> CGImage {
    guard
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else {
      throw EPDLiveFrameError.cannotCreateBitmap
    }

    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.setAllowsFontSmoothing(false)
    context.setShouldSmoothFonts(false)
    context.setFillColor(white)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    drawHeader(content, in: context)
    drawWeekStrip(content, in: context)
    drawQuotaPanel(content, in: context)
    drawTokenPanel(content, in: context)
    drawFooter(content, in: context)

    guard let image = context.makeImage() else {
      throw EPDLiveFrameError.cannotCreateBitmap
    }
    return image
  }

  private static func drawHeader(
    _ content: EPDLiveContent,
    in context: CGContext
  ) {
    drawPixelText(
      "CODEX MONITOR",
      x: 12,
      top: 9,
      scale: 2,
      color: red,
      in: context
    )
    drawPixelText(
      formatted(content.now, "yyyy.MM.dd", content.timeZone),
      x: 389,
      top: 3,
      scale: 2,
      color: black,
      alignment: .right,
      in: context
    )
    drawPixelText(
      formatted(content.now, "EEEE", content.timeZone).uppercased(),
      x: 389,
      top: 21,
      scale: 2,
      color: red,
      alignment: .right,
      in: context
    )
    drawLine(
      from: CGPoint(x: 11, y: 44), to: CGPoint(x: 389, y: 44), width: 2, color: black, in: context)
  }

  private static func drawWeekStrip(
    _ content: EPDLiveContent,
    in context: CGContext
  ) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = content.timeZone
    let dayStart = calendar.startOfDay(for: content.now)
    let weekday = calendar.component(.weekday, from: dayStart)
    let daysSinceMonday = (weekday + 5) % 7
    guard
      let weekStart = calendar.date(
        byAdding: .day,
        value: -daysSinceMonday,
        to: dayStart
      )
    else { return }

    let labels = ["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"]
    let left: CGFloat = 11
    let right: CGFloat = 389
    let top: CGFloat = 50
    let bottom: CGFloat = 94
    let cellWidth = (right - left + 1) / 7

    for index in labels.indices {
      guard
        let day = calendar.date(byAdding: .day, value: index, to: weekStart)
      else { continue }
      let x1 = (left + CGFloat(index) * cellWidth).rounded()
      let x2 = (left + CGFloat(index + 1) * cellWidth).rounded() - 1
      let isToday = calendar.isDate(day, inSameDayAs: content.now)
      let isWeekend = index >= 5
      strokeRect(
        CGRect(x: x1, y: top, width: x2 - x1, height: bottom - top),
        width: isToday ? 3 : 1,
        color: isToday ? red : black,
        in: context
      )
      drawPixelText(
        labels[index],
        x: (x1 + x2) / 2,
        top: top + 3,
        scale: 2,
        color: isToday || isWeekend ? red : black,
        alignment: .center,
        in: context
      )
      drawPixelText(
        String(calendar.component(.day, from: day)),
        x: (x1 + x2) / 2,
        top: top + 20,
        scale: 3,
        color: isToday ? black : (isWeekend ? red : black),
        alignment: .center,
        in: context
      )
    }
  }

  private static func drawQuotaPanel(
    _ content: EPDLiveContent,
    in context: CGContext
  ) {
    drawLine(
      from: CGPoint(x: 202, y: 106), to: CGPoint(x: 202, y: 266), width: 1, color: black,
      in: context)
    drawText(
      "本周额度", x: 12, top: 108, size: 14, color: red, fontName: "HiraginoSansGB-W6", in: context)

    let remaining = Int(content.remainingPercent.rounded())
    let used = Int((100 - content.remainingPercent).rounded())
    let remainingText = String(remaining)
    drawText(
      remainingText, x: 12, top: 124, size: 56, color: black, fontName: "HelveticaNeue",
      in: context)
    drawText(
      "%", x: 12 + textWidth(remainingText, size: 56, fontName: "HelveticaNeue") + 6,
      top: 156, size: 19, color: black, fontName: "HelveticaNeue-Medium", in: context)

    let bar = CGRect(x: 12, y: 185, width: 177, height: 10)
    strokeRect(bar, width: 1, color: black, in: context)
    let fillWidth = ((bar.width - 3) * content.remainingPercent / 100).rounded()
    if fillWidth > 0 {
      fillRect(CGRect(x: 14, y: 187, width: fillWidth, height: 6), color: red, in: context)
    }

    drawText(
      "本周已用", x: 12, top: 202, size: 11, color: black, fontName: "HiraginoSansGB-W3", in: context)
    drawText(
      "\(used)%", x: 189, top: 200, size: 14, color: black, fontName: "HelveticaNeue-Medium",
      alignment: .right, in: context)
    drawText(
      "下次重置", x: 12, top: 223, size: 11, color: black, fontName: "HiraginoSansGB-W3", in: context)
    drawPixelText(
      content.resetsAt.map { formatted($0, "MM-dd HH:mm", content.timeZone) } ?? "—",
      x: 189,
      top: 221,
      scale: 2,
      color: black,
      alignment: .right,
      in: context
    )
    drawLine(
      from: CGPoint(x: 12, y: 246), to: CGPoint(x: 189, y: 246), width: 1, color: black, in: context
    )
    drawText(
      "累计 Token", x: 12, top: 251, size: 11, color: black, fontName: "HiraginoSansGB-W3",
      in: context)
    drawPixelText(
      content.lifetimeTokens.map(compactTokens) ?? "—",
      x: 189,
      top: 250,
      scale: 2,
      color: red,
      alignment: .right,
      in: context
    )
  }

  private static func drawTokenPanel(
    _ content: EPDLiveContent,
    in context: CGContext
  ) {
    let chartLeft: CGFloat = 228
    let chartRight: CGFloat = 382
    let chartTop: CGFloat = 139
    let chartBottom: CGFloat = 228
    let buckets = normalizedBuckets(content)
    let values = buckets.map(\.tokens)

    drawText(
      "近 7 日 TOKEN", x: 214, top: 108, size: 14, color: red, fontName: "HiraginoSansGB-W6",
      in: context)
    drawText(
      "今日 \(compactTokens(values.last ?? 0))",
      x: chartRight,
      top: 112,
      size: 11,
      color: black,
      fontName: "HiraginoSansGB-W3",
      alignment: .right,
      in: context
    )

    let maximum = chartMaximum(values.max() ?? 0)
    for fraction in [0.0, 0.5, 1.0] {
      let y = (chartBottom - CGFloat(fraction) * (chartBottom - chartTop)).rounded()
      drawLine(
        from: CGPoint(x: chartLeft, y: y), to: CGPoint(x: chartRight, y: y), width: 1, color: black,
        in: context)
      drawPixelText(
        compactTokens(Int64((Double(maximum) * fraction).rounded())),
        x: chartLeft - 5,
        top: y - 4,
        scale: 1,
        color: black,
        alignment: .right,
        in: context
      )
    }

    var points: [CGPoint] = []
    for index in values.indices {
      let x = (chartLeft + CGFloat(index) * (chartRight - chartLeft) / 6).rounded()
      let y =
        (chartBottom
        - CGFloat(values[index]) / CGFloat(maximum) * (chartBottom - chartTop)).rounded()
      points.append(CGPoint(x: x, y: y))
    }
    if points.count > 1 {
      for index in 1..<points.count {
        drawLine(from: points[index - 1], to: points[index], width: 3, color: red, in: context)
      }
    }
    for point in points {
      fillEllipse(
        CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6),
        color: red,
        in: context
      )
    }

    for index in buckets.indices {
      let x = (chartLeft + CGFloat(index) * (chartRight - chartLeft) / 6).rounded()
      drawPixelText(
        weekdayLabel(buckets[index].startDate, content.timeZone),
        x: x,
        top: 238,
        scale: 1,
        color: isWeekend(buckets[index].startDate, content.timeZone) ? red : black,
        alignment: .center,
        in: context
      )
    }
  }

  private static func drawFooter(
    _ content: EPDLiveContent,
    in context: CGContext
  ) {
    drawLine(
      from: CGPoint(x: 11, y: 270), to: CGPoint(x: 389, y: 270), width: 2, color: black, in: context
    )
    drawText(
      "更新 \(formatted(content.updatedAt, "HH:mm", content.timeZone)) · 每小时同步",
      x: 12,
      top: 276,
      size: 11,
      color: black,
      fontName: "HiraginoSansGB-W3",
      in: context
    )
    drawText(
      "自动同步 · BLE 低功耗",
      x: 389,
      top: 276,
      size: 11,
      color: red,
      fontName: "HiraginoSansGB-W6",
      alignment: .right,
      in: context
    )
  }

  private static func normalizedBuckets(
    _ content: EPDLiveContent
  ) -> [SharedDailyTokenUsage] {
    var valuesByDate: [String: Int64] = [:]
    for bucket in content.dailyTokenUsage {
      valuesByDate[bucket.startDate, default: 0] += bucket.tokens
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = content.timeZone
    return (-6...0).compactMap { offset in
      guard let day = calendar.date(byAdding: .day, value: offset, to: content.now)
      else { return nil }
      let key = formatted(day, "yyyy-MM-dd", content.timeZone)
      return SharedDailyTokenUsage(startDate: key, tokens: valuesByDate[key] ?? 0)
    }
  }

  private static func weekdayLabel(_ dateString: String, _ timeZone: TimeZone) -> String {
    guard let date = parsedDate(dateString, timeZone) else { return "—" }
    return formatted(date, "EEE", timeZone).uppercased()
  }

  private static func isWeekend(
    _ dateString: String,
    _ timeZone: TimeZone
  ) -> Bool {
    guard let date = parsedDate(dateString, timeZone) else { return false }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar.isDateInWeekend(date)
  }

  private static func parsedDate(
    _ dateString: String,
    _ timeZone: TimeZone
  ) -> Date? {
    let parser = DateFormatter()
    parser.calendar = Calendar(identifier: .gregorian)
    parser.locale = Locale(identifier: "en_US_POSIX")
    parser.timeZone = timeZone
    parser.dateFormat = "yyyy-MM-dd"
    return parser.date(from: dateString)
  }

  private static func formatted(
    _ date: Date,
    _ format: String,
    _ timeZone: TimeZone
  ) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = format
    return formatter.string(from: date)
  }

  private static func chartMaximum(_ value: Int64) -> Int64 {
    guard value > 0 else { return 1_000_000 }
    let magnitude = pow(10, floor(log10(Double(value))))
    let normalized = Double(value) / magnitude
    let rounded: Double
    if normalized <= 1 {
      rounded = 1
    } else if normalized <= 2 {
      rounded = 2
    } else if normalized <= 5 {
      rounded = 5
    } else {
      rounded = 10
    }
    return max(1, Int64(rounded * magnitude))
  }

  private static func compactTokens(_ value: Int64) -> String {
    if value >= 1_000_000_000 {
      return compact(value: Double(value) / 1_000_000_000, suffix: "B")
    }
    if value >= 1_000_000 {
      return compact(value: Double(value) / 1_000_000, suffix: "M")
    }
    if value >= 1_000 {
      return String(format: "%.0fK", Double(value) / 1_000)
    }
    return String(value)
  }

  private static func compact(value: Double, suffix: String) -> String {
    if value.rounded() == value {
      return "\(Int(value))\(suffix)"
    }
    return String(format: "%.1f%@", value, suffix)
  }

  private enum TextAlignment {
    case left
    case center
    case right
  }

  /// A fixed 5×7 grid for small monochrome text. Integer scaling keeps every
  /// glyph on one baseline and avoids CoreText hinting artifacts on the EPD.
  private static let pixelGlyphs: [Character: [UInt8]] = [
    " ": [0, 0, 0, 0, 0, 0, 0],
    ".": [0, 0, 0, 0, 0, 0b01100, 0b01100],
    ":": [0, 0b01100, 0b01100, 0, 0b01100, 0b01100, 0],
    "-": [0, 0, 0, 0b11111, 0, 0, 0],
    "%": [0b11001, 0b11010, 0b00100, 0b01000, 0b10110, 0b00110, 0],
    "?": [0b01110, 0b10001, 0b00010, 0b00100, 0b00100, 0, 0b00100],
    "0": [0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110],
    "1": [0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110],
    "2": [0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111],
    "3": [0b11110, 0b00001, 0b00001, 0b01110, 0b00001, 0b00001, 0b11110],
    "4": [0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010],
    "5": [0b11111, 0b10000, 0b10000, 0b11110, 0b00001, 0b00001, 0b11110],
    "6": [0b01110, 0b10000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110],
    "7": [0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000],
    "8": [0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110],
    "9": [0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00001, 0b01110],
    "A": [0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001],
    "B": [0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110],
    "C": [0b01111, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b01111],
    "D": [0b11110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b11110],
    "E": [0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111],
    "F": [0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000],
    "G": [0b01110, 0b10001, 0b10000, 0b10111, 0b10001, 0b10001, 0b01110],
    "H": [0b10001, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001],
    "I": [0b01110, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110],
    "J": [0b00111, 0b00010, 0b00010, 0b00010, 0b10010, 0b10010, 0b01100],
    "K": [0b10001, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010, 0b10001],
    "L": [0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111],
    "M": [0b10001, 0b11011, 0b10101, 0b10101, 0b10001, 0b10001, 0b10001],
    "N": [0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001, 0b10001],
    "O": [0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110],
    "P": [0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000],
    "Q": [0b01110, 0b10001, 0b10001, 0b10001, 0b10101, 0b10010, 0b01101],
    "R": [0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001],
    "S": [0b01111, 0b10000, 0b10000, 0b01110, 0b00001, 0b00001, 0b11110],
    "T": [0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100],
    "U": [0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110],
    "V": [0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100],
    "W": [0b10001, 0b10001, 0b10001, 0b10101, 0b10101, 0b10101, 0b01010],
    "X": [0b10001, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001, 0b10001],
    "Y": [0b10001, 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b00100],
    "Z": [0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b11111],
  ]

  private static func drawPixelText(
    _ text: String,
    x: CGFloat,
    top: CGFloat,
    scale: Int,
    color: CGColor,
    alignment: TextAlignment = .left,
    in context: CGContext
  ) {
    let normalized = text.uppercased()
    let textWidth = pixelTextWidth(normalized, scale: scale)
    let originX: CGFloat
    switch alignment {
    case .left: originX = x
    case .center: originX = x - textWidth / 2
    case .right: originX = x - textWidth
    }
    let pixelSize = CGFloat(scale)
    for (characterIndex, character) in normalized.enumerated() {
      let rows = pixelGlyphs[character] ?? pixelGlyphs["?"]!
      let characterX = originX + CGFloat(characterIndex * 6 * scale)
      for (rowIndex, row) in rows.enumerated() {
        for column in 0..<5 where row & UInt8(1 << (4 - column)) != 0 {
          fillRect(
            CGRect(
              x: characterX + CGFloat(column) * pixelSize,
              y: top + CGFloat(rowIndex) * pixelSize,
              width: pixelSize,
              height: pixelSize
            ),
            color: color,
            in: context
          )
        }
      }
    }
  }

  private static func pixelTextWidth(_ text: String, scale: Int) -> CGFloat {
    guard !text.isEmpty else { return 0 }
    return CGFloat((text.count * 5 + text.count - 1) * scale)
  }

  private static func drawText(
    _ text: String,
    x: CGFloat,
    top: CGFloat,
    size: CGFloat,
    color: CGColor,
    fontName: String,
    alignment: TextAlignment = .left,
    in context: CGContext
  ) {
    let font = CTFontCreateWithName(fontName as CFString, size, nil)
    let attributes =
      [
        kCTFontAttributeName: font,
        kCTForegroundColorAttributeName: color,
      ] as CFDictionary
    guard
      let attributed = CFAttributedStringCreate(
        nil,
        text as CFString,
        attributes
      )
    else { return }
    let line = CTLineCreateWithAttributedString(attributed)
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    var leading: CGFloat = 0
    let textWidth = CGFloat(
      CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
    )
    let originX: CGFloat
    switch alignment {
    case .left: originX = x
    case .center: originX = x - textWidth / 2
    case .right: originX = x - textWidth
    }
    context.textPosition = CGPoint(
      x: originX.rounded(),
      y: CGFloat(height) - top - ascent
    )
    CTLineDraw(line, context)
  }

  private static func textWidth(
    _ text: String,
    size: CGFloat,
    fontName: String
  ) -> CGFloat {
    let font = CTFontCreateWithName(fontName as CFString, size, nil)
    let attributes = [kCTFontAttributeName: font] as CFDictionary
    guard
      let attributed = CFAttributedStringCreate(
        nil,
        text as CFString,
        attributes
      )
    else { return 0 }
    let line = CTLineCreateWithAttributedString(attributed)
    return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
  }

  private static func drawLine(
    from start: CGPoint,
    to end: CGPoint,
    width: CGFloat,
    color: CGColor,
    in context: CGContext
  ) {
    context.setStrokeColor(color)
    context.setLineWidth(width)
    context.move(to: CGPoint(x: start.x, y: CGFloat(height) - start.y))
    context.addLine(to: CGPoint(x: end.x, y: CGFloat(height) - end.y))
    context.strokePath()
  }

  private static func strokeRect(
    _ rect: CGRect,
    width: CGFloat,
    color: CGColor,
    in context: CGContext
  ) {
    context.setStrokeColor(color)
    context.setLineWidth(width)
    context.stroke(
      CGRect(
        x: rect.origin.x,
        y: CGFloat(height) - rect.maxY,
        width: rect.width,
        height: rect.height
      )
    )
  }

  private static func fillRect(
    _ rect: CGRect,
    color: CGColor,
    in context: CGContext
  ) {
    context.setFillColor(color)
    context.fill(
      CGRect(
        x: rect.origin.x,
        y: CGFloat(height) - rect.maxY,
        width: rect.width,
        height: rect.height
      )
    )
  }

  private static func fillEllipse(
    _ rect: CGRect,
    color: CGColor,
    in context: CGContext
  ) {
    context.setFillColor(color)
    context.fillEllipse(
      in: CGRect(
        x: rect.origin.x,
        y: CGFloat(height) - rect.maxY,
        width: rect.width,
        height: rect.height
      )
    )
  }
}

public enum EPDLiveFrameError: Error, Equatable, LocalizedError, Sendable {
  case missingUsageData
  case usageRefreshFailed(String)
  case cannotCreateBitmap
  case cannotEncodePreview

  public var errorDescription: String? {
    switch self {
    case .missingUsageData:
      return "No usage data is available for the EPD display"
    case .usageRefreshFailed(let message):
      return "Could not refresh EPD usage data: \(message)"
    case .cannotCreateBitmap:
      return "Could not render the live EPD bitmap"
    case .cannotEncodePreview:
      return "Could not encode the live EPD preview"
    }
  }
}

public enum EPDPreviewFrameError: Error, Equatable, LocalizedError, Sendable {
  case cannotDecodeImage
  case cannotCreateBitmap
  case invalidDimensions(width: Int, height: Int)

  public var errorDescription: String? {
    switch self {
    case .cannotDecodeImage:
      return "Could not decode the EPD preview image"
    case .cannotCreateBitmap:
      return "Could not create the EPD preview bitmap"
    case .invalidDimensions(let width, let height):
      return "Expected a 400×300 EPD preview, got \(width)×\(height)"
    }
  }
}
