import AppKit
import Foundation
import UniformTypeIdentifiers

/// Reads rich-text formats (HTML, RTF, RTFD, DOC, DOCX, ODT) through AppKit and converts the
/// attributed string into the format-neutral `Document`.
enum RichReader {
  static func read(url: URL, type: UTType) async throws -> Document {
    let fallbackTitle = url.deletingPathExtension().lastPathComponent
    let blocks: [Block]? = await MainActor.run {
      // HTML import must run on the main thread, and NSAttributedString is not Sendable,
      // so the conversion to plain value types happens before leaving this closure.
      guard let attributed = load(url: url, type: type) else { return nil }
      return convert(attributed)
    }
    guard let blocks else { throw BackendError.unreadable(url) }
    return Document(title: title(of: blocks) ?? fallbackTitle, blocks: blocks)
  }

  // MARK: Loading

  @MainActor
  private static func load(url: URL, type: UTType) -> NSAttributedString? {
    let ext = url.pathExtension.lowercased()
    var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
    let documentType: NSAttributedString.DocumentType?
    if type.conforms(to: .rtfd) || ext == "rtfd" {
      documentType = .rtfd
    } else if type.conforms(to: .html) || ["html", "htm", "xhtml"].contains(ext) {
      documentType = .html
      options[.characterEncoding] = String.Encoding.utf8.rawValue
      // Keep the importer from fetching or running anything remote.
      options[NSAttributedString.DocumentReadingOptionKey(rawValue: "ExcludedElements")] = [
        "script", "iframe", "object", "applet", "embed", "link", "img", "video", "audio",
      ]
    } else if type.conforms(to: .rtf) || ext == "rtf" {
      documentType = .rtf
    } else if ext == "docx" || type.identifier == "org.openxmlformats.wordprocessingml.document" {
      documentType = .officeOpenXML
    } else if ext == "doc" || type.identifier == "com.microsoft.word.doc" {
      documentType = .docFormat
    } else if ext == "odt" || type.identifier == "org.oasis-open.opendocument.text" {
      documentType = .openDocument
    } else {
      documentType = nil
    }
    if let documentType { options[.documentType] = documentType }
    return try? NSAttributedString(url: url, options: options, documentAttributes: nil)
  }

  private static func title(of blocks: [Block]) -> String? {
    for block in blocks {
      if case .heading(_, let inlines) = block {
        let text = inlines.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text.replacingOccurrences(of: "\n", with: " ") }
      }
    }
    return nil
  }

  // MARK: Conversion

  private struct ParagraphInfo {
    var range: NSRange  // without the trailing newline
    var style: NSParagraphStyle?
  }

  private static func convert(_ attributed: NSAttributedString) -> [Block] {
    let string = attributed.string as NSString
    guard string.length > 0 else { return [] }

    var paragraphs: [ParagraphInfo] = []
    var location = 0
    while location < string.length {
      var start = 0, end = 0, contentsEnd = 0
      string.getParagraphStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
      let style = attributed.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle
      paragraphs.append(ParagraphInfo(range: NSRange(location: start, length: contentsEnd - start), style: style))
      location = max(end, location + 1)
    }

    let bodySize = dominantFontSize(attributed, paragraphs)

    var blocks: [Block] = []
    var tableState: TableBuilder?

    func flushTable() {
      if let table = tableState, let block = table.block() { blocks.append(block) }
      tableState = nil
    }

    for paragraph in paragraphs {
      let style = paragraph.style
      var range = paragraph.range

      // Table cells.
      if let cell = style?.textBlocks.compactMap({ $0 as? NSTextTableBlock }).last {
        if tableState?.table !== cell.table {
          flushTable()
          tableState = TableBuilder(table: cell.table)
        }
        var skip = 0
        if let list = style?.textLists.last { skip = markerLength(in: string, range: range, list: list) }
        range = NSRange(location: range.location + skip, length: range.length - skip)
        let inlines = inlines(attributed, range, stripBold: false)
        tableState?.add(row: cell.startingRow, column: cell.startingColumn, inlines)
        continue
      }
      flushTable()

      guard range.length > 0 else { continue }
      let raw = string.substring(with: range)
      if raw.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) || $0 == "\u{FFFC}" }) {
        continue
      }

      // Lists: real text lists first, then textual markers.
      if let lists = style?.textLists, let list = lists.last {
        let skip = markerLength(in: string, range: range, list: list)
        let sub = NSRange(location: range.location + skip, length: range.length - skip)
        let content = inlines(attributed, sub, stripBold: false)
        if !content.isEmpty {
          let format = list.markerFormat.rawValue.lowercased()
          let ordered = format.contains("decimal") || format.contains("alpha") || format.contains("roman")
          blocks.append(.listItem(ordered: ordered, depth: lists.count - 1, content))
        }
        continue
      }
      if let (ordered, length) = textualMarker(raw) {
        let sub = NSRange(location: range.location + length, length: range.length - length)
        let content = inlines(attributed, sub, stripBold: false)
        if !content.isEmpty {
          blocks.append(.listItem(ordered: ordered, depth: 0, content))
          continue
        }
      }

      // Headings.
      let level = headingLevel(attributed, range: range, style: style, bodySize: bodySize)
      let content = inlines(attributed, range, stripBold: level > 0)
      guard !content.isEmpty else { continue }
      blocks.append(level > 0 ? .heading(level, content) : .paragraph(content))
    }
    flushTable()
    return blocks
  }

  private static func dominantFontSize(_ attributed: NSAttributedString, _ paragraphs: [ParagraphInfo]) -> CGFloat {
    var counts: [CGFloat: Int] = [:]
    for paragraph in paragraphs where paragraph.range.length > 0 {
      attributed.enumerateAttribute(.font, in: paragraph.range) { value, range, _ in
        if let font = value as? NSFont { counts[(font.pointSize * 2).rounded() / 2, default: 0] += range.length }
      }
    }
    return counts.max { $0.value < $1.value }?.key ?? 0
  }

  private static func headingLevel(
    _ attributed: NSAttributedString, range: NSRange, style: NSParagraphStyle?, bodySize: CGFloat
  ) -> Int {
    if let level = style?.headerLevel, level > 0 { return min(level, 6) }
    guard bodySize > 0, range.length > 0,
      let font = attributed.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
    else { return 0 }
    let ratio = font.pointSize / bodySize
    if ratio >= 1.7 { return 1 }
    if ratio >= 1.35 { return 2 }
    if ratio >= 1.15 { return 3 }
    return 0
  }

  /// Length of the "\t•\t" / "1.\t" prefix that AppKit leaves in the text of a list paragraph.
  private static func markerLength(in string: NSString, range: NSRange, list: NSTextList) -> Int {
    let text = string.substring(with: range)
    let scalars = Array(text.utf16)
    var i = 0
    while i < scalars.count, scalars[i] == 0x09 || scalars[i] == 0x20 { i += 1 }
    let markerStart = i
    while i < scalars.count, scalars[i] != 0x09, i - markerStart < 12 { i += 1 }
    if i < scalars.count, scalars[i] == 0x09, i > markerStart { return i + 1 }
    return 0
  }

  /// A leading bullet or number written as ordinary text.
  private static func textualMarker(_ text: String) -> (ordered: Bool, length: Int)? {
    let units = Array(text.utf16)
    var i = 0
    while i < units.count, units[i] == 0x09 || units[i] == 0x20 { i += 1 }
    guard i < units.count else { return nil }
    let bullets: Set<UInt16> = [0x2022, 0x25E6, 0x25AA, 0x25CF, 0x25CB, 0xB7, 0x2023, 0x2043]
    func skipSpace(_ from: Int) -> Int? {
      var j = from
      while j < units.count, units[j] == 0x09 || units[j] == 0x20 { j += 1 }
      return j > from && j < units.count ? j : nil
    }
    if bullets.contains(units[i]) {
      if let j = skipSpace(i + 1) { return (false, j) }
      return nil
    }
    if units[i] == 0x2D || units[i] == 0x2A {  // "- " or "* "
      if let j = skipSpace(i + 1) { return (false, j) }
      return nil
    }
    var digits = 0
    var k = i
    while k < units.count, units[k] >= 0x30, units[k] <= 0x39, digits < 4 { k += 1; digits += 1 }
    if digits > 0, k < units.count, units[k] == 0x2E || units[k] == 0x29, let j = skipSpace(k + 1) {
      return (true, j)
    }
    return nil
  }

  private static func inlines(_ attributed: NSAttributedString, _ range: NSRange, stripBold: Bool) -> [Inline] {
    guard range.length > 0 else { return [] }
    var result: [Inline] = []
    attributed.enumerateAttributes(in: range) { attributes, runRange, _ in
      var text = (attributed.string as NSString).substring(with: runRange)
      text = text.replacingOccurrences(of: "\u{FFFC}", with: "")
        .replacingOccurrences(of: "\u{2028}", with: "\n")
        .replacingOccurrences(of: "\u{000B}", with: "\n")
        .replacingOccurrences(of: "\u{00A0}", with: " ")
      guard !text.isEmpty else { return }
      var inline = Inline(text)
      if let font = attributes[.font] as? NSFont {
        let traits = font.fontDescriptor.symbolicTraits
        inline.bold = !stripBold && traits.contains(.bold)
        inline.italic = traits.contains(.italic)
        inline.code = traits.contains(.monoSpace) || font.isFixedPitch
      }
      if let strike = attributes[.strikethroughStyle] as? Int, strike != 0 { inline.strike = true }
      if let link = attributes[.link] {
        if let url = link as? URL { inline.link = url.absoluteString }
        else if let string = link as? String { inline.link = string }
      }
      result.append(inline)
    }
    // Trim the paragraph's outer whitespace.
    if var first = result.first {
      first.text = String(first.text.drop { $0 == " " || $0 == "\t" })
      result[0] = first
    }
    if var last = result.last {
      while last.text.last == " " || last.text.last == "\t" || last.text.last == "\n" { last.text.removeLast() }
      result[result.count - 1] = last
    }
    return result.filter { !$0.text.isEmpty }
  }

  private struct TableBuilder {
    let table: NSTextTable
    var cells: [Int: [Int: [Inline]]] = [:]

    init(table: NSTextTable) { self.table = table }

    mutating func add(row: Int, column: Int, _ inlines: [Inline]) {
      guard !inlines.isEmpty else { return }
      var existing = cells[row]?[column] ?? []
      if !existing.isEmpty { existing.append(Inline("\n")) }
      cells[row, default: [:]][column] = existing + inlines
    }

    func block() -> Block? {
      guard let maxRow = cells.keys.max() else { return nil }
      let maxColumn = cells.values.flatMap(\.keys).max() ?? 0
      let grid: [[[Inline]]] = (0...maxRow).map { r in (0...maxColumn).map { c in cells[r]?[c] ?? [] } }
      return .table(header: grid[0], rows: Array(grid.dropFirst()))
    }
  }
}
