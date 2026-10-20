import Foundation
import UniformTypeIdentifiers

/// Reads text-like files (Markdown, plain text, CSV/TSV, source and data files) into a `Document`.
/// HTML and RTF have their own readers and are not handled here.
enum TextReader {
  static func read(url: URL, type: UTType) throws -> Document {
    let text = try decode(url)
    let baseName = url.deletingPathExtension().lastPathComponent
    let ext = url.pathExtension.lowercased()
    let title = baseName.isEmpty ? url.lastPathComponent : baseName

    let markdownType = UTType("net.daringfireball.markdown")
    if ["md", "markdown", "mdown", "mkd"].contains(ext) || (markdownType.map { type.conforms(to: $0) } ?? false) {
      let blocks = MarkdownParser.parse(text)
      var heading: String?
      for case .heading(_, let inlines) in blocks {
        let plain = inlines.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        if !plain.isEmpty { heading = plain; break }
      }
      return Document(title: heading ?? title, blocks: blocks)
    }

    if ext == "csv" || type.conforms(to: .commaSeparatedText) {
      return Document(title: title, blocks: tableBlocks(text, delimiter: ","))
    }
    if ext == "tsv" || ext == "tab" || type.conforms(to: .tabSeparatedText) {
      return Document(title: title, blocks: tableBlocks(text, delimiter: "\t"))
    }

    let plainExtensions: Set<String> = ["txt", "text", ""]
    if plainExtensions.contains(ext) || type == .plainText {
      return Document(title: title, blocks: plainBlocks(text))
    }

    let body = text.hasSuffix("\n") ? String(text.dropLast()) : text
    return Document(title: title, blocks: [.code(language: language(for: ext), text: body)])
  }

  // MARK: Decoding

  static func decode(_ url: URL) throws -> String {
    var encoding = String.Encoding.utf8
    var text: String
    if let decoded = try? String(contentsOf: url, usedEncoding: &encoding) {
      text = decoded
    } else {
      guard let data = try? Data(contentsOf: url) else { throw BackendError.unreadable(url) }
      if let utf16 = String(data: data, encoding: .utf16), data.count % 2 == 0,
        data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
      {
        text = utf16
      } else if let latin = String(data: data, encoding: .isoLatin1) {
        text = latin
      } else if let utf16 = String(data: data, encoding: .utf16) {
        text = utf16
      } else {
        throw BackendError.unreadable(url)
      }
    }
    if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
    return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
  }

  // MARK: Plain text

  private static func plainBlocks(_ text: String) -> [Block] {
    var blocks: [Block] = []
    var current: [String] = []
    func flush() {
      if !current.isEmpty { blocks.append(.paragraph([Inline(current.joined(separator: "\n"))])) }
      current = []
    }
    for raw in text.components(separatedBy: "\n") {
      let line = raw.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
      if line.allSatisfy({ $0 == " " || $0 == "\t" }) { flush() } else { current.append(line) }
    }
    flush()
    return blocks
  }

  // MARK: Delimited text

  private static func tableBlocks(_ text: String, delimiter: Character) -> [Block] {
    var rows = parseDelimited(text, delimiter: delimiter)
    rows = rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    guard let first = rows.first else { return [] }
    let columns = rows.map(\.count).max() ?? first.count
    func cells(_ row: [String]) -> [[Inline]] {
      (0..<columns).map { Inline.plain($0 < row.count ? row[$0] : "") }
    }
    return [.table(header: cells(first), rows: rows.dropFirst().map(cells))]
  }

  /// RFC 4180: quoted fields may contain delimiters, newlines and doubled quotes.
  static func parseDelimited(_ text: String, delimiter: Character) -> [[String]] {
    var rows: [[String]] = []
    var row: [String] = []
    var field = ""
    var inQuotes = false
    var fieldStarted = false
    let characters = Array(text)
    var i = 0
    while i < characters.count {
      let c = characters[i]
      if inQuotes {
        if c == "\"" {
          if i + 1 < characters.count, characters[i + 1] == "\"" {
            field.append("\"")
            i += 1
          } else {
            inQuotes = false
          }
        } else {
          field.append(c)
        }
      } else if c == "\"" && !fieldStarted {
        inQuotes = true
        fieldStarted = true
      } else if c == delimiter {
        row.append(field)
        field = ""
        fieldStarted = false
      } else if c == "\n" || c == "\r\n" {
        row.append(field)
        rows.append(row)
        row = []
        field = ""
        fieldStarted = false
      } else {
        field.append(c)
        fieldStarted = true
      }
      i += 1
    }
    if fieldStarted || !field.isEmpty || !row.isEmpty {
      row.append(field)
      rows.append(row)
    }
    return rows
  }

  // MARK: Source

  private static func language(for ext: String) -> String? {
    let aliases = [
      "yml": "yaml", "py": "python", "rs": "rust", "rb": "ruby", "js": "javascript",
      "ts": "typescript", "kt": "kotlin", "sh": "bash", "zsh": "bash", "htm": "html",
    ]
    if ext.isEmpty { return nil }
    return aliases[ext] ?? ext
  }
}
