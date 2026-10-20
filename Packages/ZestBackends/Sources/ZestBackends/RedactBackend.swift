import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision
import ZestCore

/// Finds sensitive strings in text. Pure and deterministic, so it is unit-tested directly.
enum SensitiveText {
  private static func regex(_ pattern: String) -> NSRegularExpression {
    // swiftlint:disable:next force_try
    try! NSRegularExpression(pattern: pattern)
  }

  private static let email = regex(
    #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}"#)
  private static let ssn = regex(#"(?<![\d\-])\d{3}-\d{2}-\d{4}(?![\d\-])"#)
  private static let ipv4 = regex(
    #"(?<![\d.])(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?![\d]|\.\d)"#)
  private static let iban = regex(#"(?<![A-Za-z0-9])[A-Z]{2}\d{2}(?: ?[A-Za-z0-9]{1,4}){3,8}(?![A-Za-z0-9])"#)
  private static let card = regex(#"(?<![\d\-])\d(?:[ \-]?\d){12,18}(?![\d\-])"#)
  private static let phone = regex(#"(?<![\w+\-.])\+?\(?\d(?:[ \-]?[\d()]){5,}(?![\w\-])"#)
  private static let dottedPhone = regex(#"(?<![\d.])\d{3}\.\d{3}\.\d{4}(?![\d.])"#)
  private static let datePatterns = regex(
    #"^(?:\d{4}-\d{1,2}-\d{1,2}|\d{1,2}-\d{1,2}-\d{2,4})$"#)

  static func ranges(in text: String) -> [Range<String.Index>] {
    let ns = text as NSString
    let whole = NSRange(location: 0, length: ns.length)
    var found: [NSRange] = []

    func scan(_ expression: NSRegularExpression, accept: (String) -> Bool = { _ in true }) {
      for match in expression.matches(in: text, range: whole) where accept(ns.substring(with: match.range)) {
        found.append(match.range)
      }
    }

    scan(email)
    scan(ssn) { value in
      let parts = value.split(separator: "-")
      guard parts.count == 3 else { return false }
      return parts[0] != "000" && parts[0] != "666" && !parts[0].hasPrefix("9")
        && parts[1] != "00" && parts[2] != "0000"
    }
    scan(ipv4)
    // The pattern also swallows a following word ("... 32 end"), so drop trailing groups
    // until what is left is a valid IBAN.
    for match in iban.matches(in: text, range: whole) {
      var value = ns.substring(with: match.range)
      while !ibanIsValid(value), let space = value.lastIndex(of: " ") { value = String(value[..<space]) }
      if ibanIsValid(value) {
        found.append(NSRange(location: match.range.location, length: (value as NSString).length))
      }
    }
    scan(card) { value in
      let digits = value.filter(\.isNumber).map { Int(String($0))! }
      return (13...19).contains(digits.count) && luhn(digits)
    }
    scan(phone) { value in
      let digitCount = value.filter(\.isNumber).count
      guard (7...15).contains(digitCount) else { return false }
      let trimmed = value.trimmingCharacters(in: .whitespaces)
      if datePatterns.firstMatch(
        in: trimmed, range: NSRange(location: 0, length: (trimmed as NSString).length)) != nil
      {
        return false
      }
      let structured = value.contains { "+( -".contains($0) }
      // Bare digit runs are only phones at the usual lengths; otherwise they are ids or counts.
      return structured || digitCount == 10 || digitCount == 11
    }
    scan(dottedPhone)

    // Merge overlapping or touching matches.
    let sorted = found.sorted { $0.location < $1.location }
    var merged: [NSRange] = []
    for range in sorted {
      if let last = merged.last, range.location <= NSMaxRange(last) {
        merged[merged.count - 1] = NSUnionRange(last, range)
      } else {
        merged.append(range)
      }
    }
    return merged.compactMap { Range($0, in: text) }
  }

  static func luhn(_ digits: [Int]) -> Bool {
    var sum = 0
    for (offset, digit) in digits.reversed().enumerated() {
      if offset % 2 == 1 {
        let doubled = digit * 2
        sum += doubled > 9 ? doubled - 9 : doubled
      } else {
        sum += digit
      }
    }
    return sum % 10 == 0
  }

  static func ibanIsValid(_ value: String) -> Bool {
    let compact = value.replacingOccurrences(of: " ", with: "").uppercased()
    guard (15...34).contains(compact.count) else { return false }
    let rearranged = compact.dropFirst(4) + compact.prefix(4)
    var remainder = 0
    for character in rearranged {
      guard let scalar = character.unicodeScalars.first else { return false }
      let number: Int
      if character.isNumber, let digit = character.wholeNumberValue {
        number = digit
        remainder = (remainder * 10 + number) % 97
      } else if scalar.value >= 65 && scalar.value <= 90 {
        number = Int(scalar.value) - 55
        remainder = (remainder * 100 + number) % 97
      } else {
        return false
      }
    }
    return remainder == 1
  }

  static func redacted(_ text: String, placeholder: String = "[REDACTED]") -> String? {
    let matches = ranges(in: text)
    guard !matches.isEmpty else { return nil }
    var result = text
    for range in matches.reversed() { result.replaceSubrange(range, with: placeholder) }
    return result
  }
}

/// Automatic redaction: finds emails, phone numbers, SSNs, card numbers, IPv4 addresses and
/// IBANs and permanently removes them. Images and PDF pages are rasterised with the matches
/// burned in black, so the text is gone from the file, not just covered.
public struct RedactBackend: ToolBackend {
  public let id = "redact"

  public init() {}

  static let pdfScale = 200.0 / 72.0
  static let imagePadding = 4.0

  public func capabilities() -> [Capability] { [] }

  public func tools() -> [ToolSpec] {
    [
      ToolSpec(
        id: "redact.auto", backendID: id, root: .edit, title: "Auto-redact", symbol: "lock.doc",
        shape: .transform,
        accepts: [.pdf, .rtf, .text, .jpeg, .png, .heic, .tiff, .bmp],
        nameSuffix: " redacted")
    ]
  }

  public func run(_ job: JobSpec, progress: Progress) async throws -> [URL] { [] }

  public func runTool(_ job: ToolJob, progress: Progress) async throws -> ToolResult {
    guard job.tool.id == "redact.auto" else { throw ZestError.backendMissing(job.tool.id) }
    var outputs: [ToolOutput] = []
    var skipped: [ToolSkip] = []
    for (index, url) in job.inputs.enumerated() {
      try Task.checkCancellation()
      let ext = url.pathExtension
      let out = job.outputDirectory.appendingPathComponent(
        "\(index)-\(url.deletingPathExtension().lastPathComponent).\(ext)")
      let type = UTType(filenameExtension: ext.lowercased())
      let wrote: Bool
      if type?.conforms(to: .rtf) == true {
        wrote = try redactRTF(url, to: out)
      } else if type?.conforms(to: .pdf) == true {
        wrote = try redactPDF(url, to: out)
      } else if let type, type.conforms(to: .image) {
        wrote = try redactImage(url, type: type, to: out)
      } else {
        wrote = try redactText(url, to: out)
      }
      if wrote {
        outputs.append(ToolOutput(url: out, source: index))
      } else {
        skipped.append(ToolSkip(source: index, reason: "Nothing sensitive found"))
      }
    }
    return ToolResult(outputs: outputs, skipped: skipped)
  }

  // MARK: Text

  private func redactText(_ url: URL, to out: URL) throws -> Bool {
    var encoding = String.Encoding.utf8
    guard let text = try? String(contentsOf: url, usedEncoding: &encoding) else {
      throw BackendError.unreadable(url)
    }
    guard let result = SensitiveText.redacted(text) else { return false }
    do { try result.write(to: out, atomically: true, encoding: .utf8) } catch {
      throw BackendError.encodeFailed(out.lastPathComponent)
    }
    return true
  }

  private func redactRTF(_ url: URL, to out: URL) throws -> Bool {
    guard
      let attributed = try? NSMutableAttributedString(
        url: url, options: [.documentType: NSAttributedString.DocumentType.rtf],
        documentAttributes: nil)
    else { throw BackendError.unreadable(url) }
    let matches = SensitiveText.ranges(in: attributed.string)
    guard !matches.isEmpty else { return false }
    for range in matches.reversed() {
      attributed.replaceCharacters(in: NSRange(range, in: attributed.string), with: "[REDACTED]")
    }
    let full = NSRange(location: 0, length: attributed.length)
    guard
      let data = try? attributed.data(
        from: full, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    else { throw BackendError.encodeFailed(out.lastPathComponent) }
    do { try data.write(to: out) } catch { throw BackendError.encodeFailed(out.lastPathComponent) }
    return true
  }

  // MARK: Images

  /// Pixel rects (bottom-left origin) of every sensitive string Vision can read.
  static func sensitiveRects(in image: CGImage, padding: Double) throws -> [CGRect] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    var rects: [CGRect] = []
    for observation in request.results ?? [] {
      guard let candidate = observation.topCandidates(1).first else { continue }
      let text = candidate.string
      for range in SensitiveText.ranges(in: text) {
        guard let box = try? candidate.boundingBox(for: range) else { continue }
        let rect = VNImageRectForNormalizedRect(box.boundingBox, image.width, image.height)
        rects.append(rect.insetBy(dx: -padding, dy: -padding))
      }
    }
    return rects
  }

  private func redactImage(_ url: URL, type: UTType, to out: URL) throws -> Bool {
    guard let image = OrientedImage.load(url) else { throw BackendError.unreadable(url) }
    let rects = try Self.sensitiveRects(in: image, padding: Self.imagePadding)
    guard !rects.isEmpty else { return false }
    guard
      let context = CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw BackendError.encodeFailed(out.lastPathComponent) }
    let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    if !type.conforms(to: .png) {
      context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
      context.fill(bounds)
    }
    context.draw(image, in: bounds)
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    for rect in rects { context.fill(rect) }
    guard let result = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
        out as CFURL, type.identifier as CFString, 1, nil)
    else { throw BackendError.encodeFailed(out.lastPathComponent) }
    // Deliberately no source properties: EXIF, GPS and thumbnails stay behind.
    let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.92]
    CGImageDestinationAddImage(destination, result, options as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      throw BackendError.encodeFailed(out.lastPathComponent)
    }
    return true
  }

  // MARK: PDF

  private func renderPage(_ page: PDFPage) -> CGImage? {
    let box = page.bounds(for: .mediaBox)
    let scale = Self.pdfScale
    let width = Int((box.width * scale).rounded())
    let height = Int((box.height * scale).rounded())
    guard width > 0, height > 0,
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: -box.minX, y: -box.minY)
    page.draw(with: .mediaBox, to: context)
    return context.makeImage()
  }

  /// Black-box rects in pixel space of the 200 DPI render, or nil if the page needs no change.
  private func pageRects(_ page: PDFPage, render: () -> CGImage?) throws -> (CGImage, [CGRect])? {
    let box = page.bounds(for: .mediaBox)
    let text = page.string ?? ""
    var rects: [CGRect] = []
    var image: CGImage?
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      guard let rendered = render() else { throw BackendError.encodeFailed("page render") }
      image = rendered
      rects = try Self.sensitiveRects(in: rendered, padding: Self.imagePadding)
    } else {
      let pad = 2.0
      for range in SensitiveText.ranges(in: text) {
        guard let selection = page.selection(for: NSRange(range, in: text)) else { continue }
        for line in selection.selectionsByLine() {
          let b = line.bounds(for: page).insetBy(dx: -pad, dy: -pad)
          rects.append(
            CGRect(
              x: (b.minX - box.minX) * Self.pdfScale, y: (b.minY - box.minY) * Self.pdfScale,
              width: b.width * Self.pdfScale, height: b.height * Self.pdfScale))
        }
      }
      // Text drawn inside embedded images has no text layer, so OCR the render as well.
      if let rendered = render() {
        rects += try Self.sensitiveRects(in: rendered, padding: Self.imagePadding)
        if !rects.isEmpty { image = rendered }
      } else if !rects.isEmpty {
        // Never fall back to the original page when it needs redacting.
        throw BackendError.encodeFailed("page render")
      }
    }
    guard let image, !rects.isEmpty else { return nil }
    return (image, rects)
  }

  private func redactPDF(_ url: URL, to out: URL) throws -> Bool {
    guard let source = PDFDocument(url: url), source.pageCount > 0 else {
      throw BackendError.unreadable(url)
    }
    let result = PDFDocument()
    var changed = false
    for index in 0..<source.pageCount {
      try Task.checkCancellation()
      guard let page = source.page(at: index) else { continue }
      let box = page.bounds(for: .mediaBox)
      if let (image, rects) = try pageRects(page, render: { renderPage(page) }) {
        guard let burned = burn(rects, into: image) else {
          throw BackendError.encodeFailed(out.lastPathComponent)
        }
        let nsImage = NSImage(cgImage: burned, size: box.size)
        if let raster = PDFPage(image: nsImage, options: [.mediaBox: NSValue(rect: box)]) {
          result.insert(raster, at: result.pageCount)
          changed = true
          continue
        }
        throw BackendError.encodeFailed(out.lastPathComponent)
      }
      if let copy = page.copy() as? PDFPage { result.insert(copy, at: result.pageCount) }
    }
    guard changed else { return false }
    result.documentAttributes = [:]
    guard result.write(to: out) else { throw BackendError.encodeFailed(out.lastPathComponent) }
    return true
  }

  private func burn(_ rects: [CGRect], into image: CGImage) -> CGImage? {
    guard
      let context = CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    for rect in rects { context.fill(rect) }
    return context.makeImage()
  }
}
