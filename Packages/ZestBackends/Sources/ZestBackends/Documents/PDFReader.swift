import AppKit
import Foundation
import PDFKit

/// Reads a PDF into the shared document model. Structure is inferred from font sizes and line
/// geometry; pages with no text layer fall back to OCR.
enum PDFReader {
  static func read(url: URL) async throws -> Document {
    guard let pdf = PDFDocument(url: url), pdf.pageCount > 0 else {
      throw BackendError.unreadable(url)
    }

    // Pass 1: extract lines for every page.
    var pages: [[Line]] = []
    for index in 0..<pdf.pageCount {
      pages.append(pdf.page(at: index).map(lines(of:)) ?? [])
    }
    let bodySize = dominantSize(pages)

    // Pass 2: build blocks.
    var blocks: [Block] = []
    for (index, pageLines) in pages.enumerated() {
      var pageBlocks: [Block]
      if pageLines.isEmpty {
        pageBlocks = []
        if let page = pdf.page(at: index), let image = render(page) {
          pageBlocks = await ocrFallback(image)
        }
      } else {
        pageBlocks = build(pageLines, bodySize: bodySize)
      }
      if pdf.pageCount > 1, index > 0, !blocks.isEmpty, !pageBlocks.isEmpty { blocks.append(.rule) }
      blocks += pageBlocks
    }

    return Document(title: title(of: pdf, blocks: blocks, url: url), blocks: blocks)
  }

  // MARK: Extraction

  private struct Run {
    var text: String
    var size: CGFloat
    var bold: Bool
    var italic: Bool
  }

  private struct Line {
    var runs: [Run]
    var bounds: CGRect
    var text: String { runs.map(\.text).joined() }
    /// Size of the majority of the line's characters.
    var size: CGFloat {
      var counts: [CGFloat: Int] = [:]
      for run in runs { counts[run.size, default: 0] += run.text.count }
      return counts.max { $0.value < $1.value }?.key ?? 0
    }
  }

  private static func lines(of page: PDFPage) -> [Line] {
    guard let selection = page.selection(for: page.bounds(for: .cropBox)) else { return [] }
    var result: [Line] = []
    for line in selection.selectionsByLine() {
      guard let attributed = line.attributedString, !attributed.string.isEmpty else { continue }
      var runs: [Run] = []
      attributed.enumerateAttribute(
        .font, in: NSRange(location: 0, length: attributed.length)
      ) { value, range, _ in
        let text = attributed.attributedSubstring(from: range).string
          .replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
        guard !text.isEmpty else { return }
        let font = value as? NSFont
        let traits = font?.fontDescriptor.symbolicTraits ?? []
        let name = font?.fontName.lowercased() ?? ""
        runs.append(
          Run(
            text: text, size: ((font?.pointSize ?? 0) * 2).rounded() / 2,
            bold: traits.contains(.bold) || name.contains("bold") || name.contains("black"),
            italic: traits.contains(.italic) || name.contains("italic") || name.contains("oblique")))
      }
      let trimmed = trim(runs)
      guard !trimmed.isEmpty else { continue }
      result.append(Line(runs: trimmed, bounds: line.bounds(for: page)))
    }
    return result
  }

  private static func trim(_ runs: [Run]) -> [Run] {
    var runs = runs
    while var first = runs.first {
      first.text = String(first.text.drop { $0.isWhitespace })
      if first.text.isEmpty { runs.removeFirst() } else { runs[0] = first; break }
    }
    while var last = runs.last {
      while let c = last.text.last, c.isWhitespace { last.text.removeLast() }
      if last.text.isEmpty { runs.removeLast() } else { runs[runs.count - 1] = last; break }
    }
    return runs
  }

  private static func dominantSize(_ pages: [[Line]]) -> CGFloat {
    var counts: [CGFloat: Int] = [:]
    for line in pages.joined() {
      for run in line.runs where run.size > 0 { counts[run.size, default: 0] += run.text.count }
    }
    return counts.max { $0.value < $1.value }?.key ?? 12
  }

  // MARK: Structure

  private static let bulletPattern = try! NSRegularExpression(
    pattern: #"^([•◦▪‣\-–]|\d{1,3}[.)])\s+"#)

  private static func build(_ lines: [Line], bodySize: CGFloat) -> [Block] {
    enum Kind: Equatable { case heading(Int), paragraph, item(ordered: Bool, depth: Int) }
    var blocks: [Block] = []
    var kind: Kind?
    var inlines: [Inline] = []
    var previous: Line?
    var listBaseX: CGFloat?

    func flush() {
      defer { kind = nil; inlines = [] }
      guard let kind, !inlines.isEmpty else { return }
      switch kind {
      case .heading(let level): blocks.append(.heading(level, inlines))
      case .paragraph: blocks.append(.paragraph(inlines))
      case .item(let ordered, let depth):
        blocks.append(.listItem(ordered: ordered, depth: depth, inlines))
      }
    }

    for line in lines {
      let text = line.text
      let ratio = bodySize > 0 ? line.size / bodySize : 1
      var lineKind: Kind
      var runs = line.runs
      var isBullet = false
      if ratio >= 1.15, text.count < 120 {
        lineKind = .heading(ratio >= 1.7 ? 1 : ratio >= 1.35 ? 2 : 3)
        runs = runs.map { var r = $0; r.bold = false; return r }
      } else if let match = bulletPattern.firstMatch(
        in: text, range: NSRange(text.startIndex..., in: text))
      {
        isBullet = true
        let marker = String(text[Range(match.range(at: 1), in: text)!])
        let base = listBaseX ?? line.bounds.minX
        if listBaseX == nil { listBaseX = base }
        let depth = max(0, Int(((line.bounds.minX - base) / (bodySize * 1.5)).rounded()))
        lineKind = .item(ordered: marker.first!.isNumber, depth: depth)
        runs = dropPrefix(runs, count: match.range.length)
      } else {
        lineKind = .paragraph
      }

      var continues = false
      if let previous, let current = kind, !isBullet {
        let gap = previous.bounds.minY - line.bounds.maxY
        let height = max(line.bounds.height, 1)
        let sameFlow = gap <= 0.5 * height && line.bounds.midY < previous.bounds.midY
        switch (current, lineKind) {
        case (.heading(let a), .heading(let b)): continues = a == b && sameFlow
        case (.paragraph, .paragraph):
          continues = sameFlow && abs(line.bounds.minX - previous.bounds.minX) <= bodySize * 1.5
        case (.item, .paragraph): continues = sameFlow
        default: continues = false
        }
      }

      if !continues {
        flush()
        kind = lineKind
        if !isBullet { listBaseX = nil }
        if case .item = lineKind {} else { listBaseX = nil }
      }
      append(runs, to: &inlines, joined: continues)
      previous = line
    }
    flush()
    return blocks
  }

  private static func dropPrefix(_ runs: [Run], count: Int) -> [Run] {
    var remaining = count
    var out: [Run] = []
    for var run in runs {
      if remaining > 0 {
        let n = min(remaining, run.text.count)
        run.text = String(run.text.dropFirst(n))
        remaining -= n
      }
      if !run.text.isEmpty { out.append(run) }
    }
    return out
  }

  private static func append(_ runs: [Run], to inlines: inout [Inline], joined: Bool) {
    var runs = runs
    if joined, var last = inlines.popLast() {
      let next = runs.first?.text.first
      if last.text.hasSuffix("-"), last.text.dropLast().last?.isLetter == true,
        next?.isLowercase == true
      {
        last.text.removeLast()
      } else {
        last.text += " "
      }
      inlines.append(last)
    }
    for run in runs.indices {
      let r = runs[run]
      let inline = Inline(r.text, bold: r.bold, italic: r.italic)
      if var last = inlines.last, last.styleKey == inline.styleKey {
        last.text += inline.text
        inlines[inlines.count - 1] = last
      } else {
        inlines.append(inline)
      }
    }
    runs.removeAll()
  }

  private static func title(of pdf: PDFDocument, blocks: [Block], url: URL) -> String {
    if let raw = pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String {
      let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if !t.isEmpty { return t }
    }
    for block in blocks {
      if case .heading(_, let inlines) = block {
        let t = inlines.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
      }
    }
    return url.deletingPathExtension().lastPathComponent
  }

  // MARK: OCR

  /// Renders at 150 DPI on white.
  private static func render(_ page: PDFPage) -> CGImage? {
    let box = page.bounds(for: .cropBox)
    let scale: CGFloat = 150.0 / 72.0
    let width = Int((box.width * scale).rounded()), height = Int((box.height * scale).rounded())
    guard width > 0, height > 0,
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: -box.minX, y: -box.minY)
    page.draw(with: .cropBox, to: context)
    return context.makeImage()
  }

  private static func ocrFallback(_ image: CGImage) async -> [Block] { ImageReader.ocrBlocks(for: image) }
}
