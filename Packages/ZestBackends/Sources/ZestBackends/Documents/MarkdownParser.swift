import Foundation

/// A compact CommonMark-ish parser that produces the format-neutral `Block` model.
/// It covers what documents actually use; anything it does not recognise stays literal text.
enum MarkdownParser {
  static func parse(_ source: String) -> [Block] {
    let text = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    let lines = text.components(separatedBy: "\n")
    var blocks: [Block] = []
    var listStack: [Int] = []
    var i = 0

    while i < lines.count {
      let line = lines[i]
      if isBlank(line) { i += 1; continue }

      // Fenced code
      if let fence = fenceOpen(line) {
        listStack = []
        var body: [String] = []
        i += 1
        while i < lines.count {
          if isFenceClose(lines[i], fence) { i += 1; break }
          body.append(stripIndent(lines[i], up: fence.indent))
          i += 1
        }
        blocks.append(.code(language: fence.language, text: body.joined(separator: "\n")))
        continue
      }

      // ATX heading
      if let (level, content) = atxHeading(line) {
        listStack = []
        blocks.append(.heading(level, InlineParser.parse(content)))
        i += 1
        continue
      }

      // Horizontal rule
      if isRule(line) {
        listStack = []
        blocks.append(.rule)
        i += 1
        continue
      }

      // Block quote
      if isQuote(line) {
        listStack = []
        var groups: [[String]] = [[]]
        while i < lines.count, isQuote(lines[i]) {
          let content = quoteContent(lines[i])
          if isBlank(content) {
            if !groups[groups.count - 1].isEmpty { groups.append([]) }
          } else {
            groups[groups.count - 1].append(content)
          }
          i += 1
        }
        for group in groups where !group.isEmpty {
          blocks.append(.quote(InlineParser.parse(joinLines(group))))
        }
        continue
      }

      // List item
      if let marker = listMarker(line) {
        var indent = marker.indent
        while let last = listStack.last, last > indent { listStack.removeLast() }
        if listStack.isEmpty || indent >= listStack[listStack.count - 1] + 2 { listStack.append(indent) }
        indent = 0
        let depth = listStack.count - 1
        var body = [marker.content]
        i += 1
        while i < lines.count, !isBlank(lines[i]), !startsBlock(lines[i]), listMarker(lines[i]) == nil {
          body.append(lines[i])
          i += 1
        }
        blocks.append(.listItem(ordered: marker.ordered, depth: depth, InlineParser.parse(joinLines(body))))
        continue
      }

      listStack = []

      // Table
      if line.contains("|"), i + 1 < lines.count, let columns = separatorColumns(lines[i + 1]) {
        let header = splitRow(line)
        if header.count == columns {
          var rows: [[[Inline]]] = []
          i += 2
          while i < lines.count, !isBlank(lines[i]), lines[i].contains("|"), fenceOpen(lines[i]) == nil {
            rows.append(splitRow(lines[i]).map { InlineParser.parse($0) })
            i += 1
          }
          blocks.append(.table(header: header.map { InlineParser.parse($0) }, rows: rows))
          continue
        }
      }

      // Paragraph or setext heading
      var para = [line]
      var setext: Int?
      i += 1
      while i < lines.count, !isBlank(lines[i]) {
        if let level = setextLevel(lines[i]) { setext = level; i += 1; break }
        if startsBlock(lines[i]) { break }
        para.append(lines[i])
        i += 1
      }
      var joined = joinLines(para)
      if let level = setext {
        blocks.append(.heading(level, InlineParser.parse(joined)))
        continue
      }
      // The Markdown writer escapes "1." at paragraph start as "\1."; undo that.
      if joined.hasPrefix("\\"), let first = joined.dropFirst().first, first.isASCII, first.isNumber {
        let digits = joined.dropFirst().prefix { $0.isASCII && $0.isNumber }
        let rest = joined.dropFirst(1 + digits.count)
        if rest.hasPrefix(".") || rest.hasPrefix(")") { joined.removeFirst() }
      }
      if let (alt, src) = InlineParser.soleImage(joined) {
        blocks.append(.image(alt: alt, src: src, dataURI: nil))
      } else {
        let inlines = InlineParser.parse(joined)
        if !inlines.isEmpty { blocks.append(.paragraph(inlines)) }
      }
    }
    return blocks
  }

  // MARK: Line classification

  private static func isBlank(_ line: String) -> Bool {
    line.allSatisfy { $0 == " " || $0 == "\t" }
  }

  private static func leadingWidth(_ line: String) -> Int {
    var width = 0
    for character in line {
      if character == " " { width += 1 } else if character == "\t" { width += 4 } else { break }
    }
    return width
  }

  private static func trimmed(_ line: String) -> String {
    line.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
  }

  private static func stripIndent(_ line: String, up count: Int) -> String {
    var removed = 0
    var index = line.startIndex
    while index < line.endIndex, removed < count, line[index] == " " {
      removed += 1
      index = line.index(after: index)
    }
    return String(line[index...])
  }

  private struct Fence {
    var character: Character
    var count: Int
    var indent: Int
    var language: String?
  }

  private static func fenceOpen(_ line: String) -> Fence? {
    let indent = leadingWidth(line)
    let body = trimmed(line)
    guard let first = body.first, first == "`" || first == "~" else { return nil }
    let run = body.prefix { $0 == first }.count
    guard run >= 3 else { return nil }
    let info = trimmed(String(body.dropFirst(run)))
    if first == "`" && info.contains("`") { return nil }
    let language = info.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init)
    return Fence(character: first, count: run, indent: indent, language: language)
  }

  private static func isFenceClose(_ line: String, _ fence: Fence) -> Bool {
    let body = trimmed(line)
    let run = body.prefix { $0 == fence.character }.count
    return run >= fence.count && run == body.count
  }

  private static func atxHeading(_ line: String) -> (Int, String)? {
    guard leadingWidth(line) <= 3 else { return nil }
    let body = trimmed(line)
    let hashes = body.prefix { $0 == "#" }.count
    guard (1...6).contains(hashes) else { return nil }
    let rest = body.dropFirst(hashes)
    guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
    var content = trimmed(String(rest))
    // Optional closing sequence of #s, only when separated by whitespace.
    let closing = content.reversed().prefix { $0 == "#" }.count
    if closing > 0 {
      let head = content.dropLast(closing)
      if head.isEmpty { content = "" } else if head.last == " " || head.last == "\t" { content = trimmed(String(head)) }
    }
    return (hashes, content)
  }

  private static func isRule(_ line: String) -> Bool {
    guard leadingWidth(line) <= 3 else { return false }
    let body = trimmed(line).filter { $0 != " " && $0 != "\t" }
    guard body.count >= 3, let first = body.first, "-*_".contains(first) else { return false }
    return body.allSatisfy { $0 == first }
  }

  private static func setextLevel(_ line: String) -> Int? {
    guard leadingWidth(line) <= 3 else { return nil }
    let body = trimmed(line)
    guard body.count >= 2, let first = body.first, first == "=" || first == "-" else { return nil }
    guard body.allSatisfy({ $0 == first }) else { return nil }
    return first == "=" ? 1 : 2
  }

  private static func isQuote(_ line: String) -> Bool {
    leadingWidth(line) <= 3 && trimmed(line).hasPrefix(">")
  }

  private static func quoteContent(_ line: String) -> String {
    var body = String(line.drop { $0 == " " || $0 == "\t" }.dropFirst())
    if body.hasPrefix(" ") { body.removeFirst() }
    return body
  }

  private struct ListMarker {
    var indent: Int
    var ordered: Bool
    var number: Int
    var content: String
  }

  private static func listMarker(_ line: String) -> ListMarker? {
    if isRule(line) { return nil }
    let indent = leadingWidth(line)
    let body = line.drop { $0 == " " || $0 == "\t" }
    guard let first = body.first else { return nil }
    if "-+*".contains(first) {
      let rest = body.dropFirst()
      guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
      return ListMarker(indent: indent, ordered: false, number: 0, content: trimmed(String(rest)))
    }
    let digits = body.prefix { $0.isASCII && $0.isNumber }
    guard (1...9).contains(digits.count) else { return nil }
    let afterDigits = body.dropFirst(digits.count)
    guard let delimiter = afterDigits.first, delimiter == "." || delimiter == ")" else { return nil }
    let rest = afterDigits.dropFirst()
    guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
    return ListMarker(
      indent: indent, ordered: true, number: Int(digits) ?? 0, content: trimmed(String(rest)))
  }

  /// Whether a line ends the paragraph or list item that precedes it.
  private static func startsBlock(_ line: String) -> Bool {
    if fenceOpen(line) != nil || atxHeading(line) != nil || isRule(line) || isQuote(line) { return true }
    if let marker = listMarker(line) {
      return !marker.ordered || marker.number == 1
    }
    return false
  }

  // MARK: Tables

  private static func separatorColumns(_ line: String) -> Int? {
    guard line.contains("-") else { return nil }
    let cells = splitRow(line)
    guard !cells.isEmpty else { return nil }
    for cell in cells {
      var body = Substring(cell)
      if body.hasPrefix(":") { body = body.dropFirst() }
      if body.hasSuffix(":") { body = body.dropLast() }
      if body.isEmpty || !body.allSatisfy({ $0 == "-" }) { return nil }
    }
    return cells.count
  }

  /// Splits a pipe row into trimmed cell strings; `\|` yields a literal pipe.
  private static func splitRow(_ line: String) -> [String] {
    var body = Array(trimmed(line))
    if body.first == "|" { body.removeFirst() }
    if body.last == "|", !(body.count >= 2 && body[body.count - 2] == "\\") { body.removeLast() }
    var cells: [String] = []
    var current = ""
    var index = 0
    while index < body.count {
      let character = body[index]
      if character == "\\", index + 1 < body.count, body[index + 1] == "|" {
        current.append("|")
        index += 2
        continue
      }
      if character == "|" {
        cells.append(trimmed(current))
        current = ""
      } else {
        current.append(character)
      }
      index += 1
    }
    cells.append(trimmed(current))
    return cells
  }

  // MARK: Line joining

  /// Joins the lines of one paragraph: soft breaks become a space, hard breaks (two trailing
  /// spaces or a trailing backslash) become "\n".
  static func joinLines(_ lines: [String]) -> String {
    var out = ""
    for (index, raw) in lines.enumerated() {
      var line = raw
      var hard = false
      let isLast = index == lines.count - 1
      if !isLast {
        if line.hasSuffix("\\") && !line.hasSuffix("\\\\") {
          hard = true
          line.removeLast()
        } else if line.hasSuffix("  ") {
          hard = true
        }
      }
      out += trimmed(line)
      if !isLast { out += hard ? "\n" : " " }
    }
    return out
  }
}

// MARK: - Inline parsing

private struct InlineStyle {
  var bold = false
  var italic = false
  var strike = false
}

private struct InlineParser {
  let s: [Character]

  static func parse(_ text: String) -> [Inline] {
    let parser = InlineParser(s: Array(text))
    return MarkdownWriter.mergedRuns(parser.run(0, parser.s.count, InlineStyle(), nil)).filter {
      !$0.text.isEmpty
    }
  }

  /// `![alt](src)` and nothing else.
  static func soleImage(_ text: String) -> (String, String)? {
    let parser = InlineParser(s: Array(text))
    guard parser.s.count >= 5, parser.s[0] == "!", parser.s[1] == "[",
      let link = parser.link(at: 1, end: parser.s.count), link.after == parser.s.count
    else { return nil }
    let alt = parse(String(parser.s[2..<link.textEnd])).map(\.text).joined()
    return (alt, link.destination)
  }

  private func isPunctuation(_ c: Character) -> Bool {
    c.isASCII && (c.isPunctuation || c.isSymbol)
  }

  func run(_ from: Int, _ end: Int, _ style: InlineStyle, _ link: String?) -> [Inline] {
    var out: [Inline] = []
    var buffer = ""
    func flush() {
      if !buffer.isEmpty {
        out.append(
          Inline(buffer, bold: style.bold, italic: style.italic, strike: style.strike, link: link))
        buffer = ""
      }
    }

    var i = from
    while i < end {
      let c = s[i]
      switch c {
      case "\\":
        if i + 1 < end, isPunctuation(s[i + 1]) {
          buffer.append(s[i + 1])
          i += 2
        } else {
          buffer.append(c)
          i += 1
        }

      case "`":
        let n = runLength(of: "`", at: i, end: end)
        if let close = closingBackticks(from: i + n, end: end, count: n) {
          flush()
          var content = String(s[(i + n)..<close]).replacingOccurrences(of: "\n", with: " ")
          if content.count >= 2, content.hasPrefix(" "), content.hasSuffix(" "),
            content.contains(where: { $0 != " " })
          {
            content = String(content.dropFirst().dropLast())
          }
          out.append(
            Inline(
              content, bold: style.bold, italic: style.italic, strike: style.strike, code: true,
              link: link))
          i = close + n
        } else {
          buffer += String(repeating: "`", count: n)
          i += n
        }

      case "*", "_":
        let r = runLength(of: c, at: i, end: end)
        let after = i + r
        var opens = after < end && !s[after].isWhitespace && (1...3).contains(r)
        if c == "_", i > 0, s[i - 1].isLetter || s[i - 1].isNumber { opens = false }
        if opens, let close = closer(c, r, from: after, end: end) {
          flush()
          var inner = style
          if r >= 2 { inner.bold = true }
          if r == 1 || r == 3 { inner.italic = true }
          out += run(after, close, inner, link)
          i = close + r
        } else {
          buffer += String(repeating: c, count: r)
          i += r
        }

      case "~":
        if i + 2 < end, s[i + 1] == "~", !s[i + 2].isWhitespace,
          let close = strikeCloser(from: i + 2, end: end)
        {
          flush()
          var inner = style
          inner.strike = true
          out += run(i + 2, close, inner, link)
          i = close + 2
        } else {
          let n = runLength(of: "~", at: i, end: end)
          buffer += String(repeating: "~", count: n)
          i += n
        }

      case "[":
        if let parsed = self.link(at: i, end: end) {
          flush()
          out += run(i + 1, parsed.textEnd, style, link ?? parsed.destination)
          i = parsed.after
        } else {
          buffer.append(c)
          i += 1
        }

      case "!":
        // Images only become blocks when alone in a paragraph; inline they degrade to a link.
        if i + 1 < end, s[i + 1] == "[", let parsed = self.link(at: i + 1, end: end) {
          flush()
          let alt = String(s[(i + 2)..<parsed.textEnd])
          let label = InlineParser.parse(alt).map(\.text).joined()
          out.append(
            Inline(
              label.isEmpty ? parsed.destination : label, bold: style.bold, italic: style.italic,
              strike: style.strike, link: link ?? parsed.destination))
          i = parsed.after
        } else {
          buffer.append(c)
          i += 1
        }

      case "<":
        if let (target, after) = autolink(at: i, end: end) {
          flush()
          let shown = target.hasPrefix("mailto:") ? String(target.dropFirst(7)) : target
          out.append(
            Inline(
              shown, bold: style.bold, italic: style.italic, strike: style.strike,
              link: link ?? target))
          i = after
        } else {
          buffer.append(c)
          i += 1
        }

      default:
        buffer.append(c)
        i += 1
      }
    }
    flush()
    return out
  }

  // MARK: Scanning helpers

  private func runLength(of character: Character, at index: Int, end: Int) -> Int {
    var n = 0
    while index + n < end, s[index + n] == character { n += 1 }
    return n
  }

  private func closingBackticks(from: Int, end: Int, count: Int) -> Int? {
    var j = from
    while j < end {
      if s[j] == "`" {
        let m = runLength(of: "`", at: j, end: end)
        if m == count { return j }
        j += m
      } else {
        j += 1
      }
    }
    return nil
  }

  /// Index after a complete code span starting at `j`, if there is one.
  private func codeSpanEnd(at j: Int, end: Int) -> Int? {
    let n = runLength(of: "`", at: j, end: end)
    return closingBackticks(from: j + n, end: end, count: n).map { $0 + n }
  }

  private func closer(_ c: Character, _ r: Int, from: Int, end: Int) -> Int? {
    var j = from
    while j < end {
      let ch = s[j]
      if ch == "\\" { j += 2; continue }
      if ch == "`" {
        j = codeSpanEnd(at: j, end: end) ?? (j + runLength(of: "`", at: j, end: end))
        continue
      }
      if ch == c {
        let m = runLength(of: c, at: j, end: end)
        let hugsText = j > from && !s[j - 1].isWhitespace
        let intraword = c == "_" && j + m < end && (s[j + m].isLetter || s[j + m].isNumber)
        if hugsText && !intraword {
          if r == 1 && m == 1 { return j }
          if r >= 2 && m >= r { return j + m - r }
        }
        j += m
        continue
      }
      j += 1
    }
    return nil
  }

  private func strikeCloser(from: Int, end: Int) -> Int? {
    var j = from
    while j < end {
      let ch = s[j]
      if ch == "\\" { j += 2; continue }
      if ch == "`" {
        j = codeSpanEnd(at: j, end: end) ?? (j + runLength(of: "`", at: j, end: end))
        continue
      }
      if ch == "~" {
        let m = runLength(of: "~", at: j, end: end)
        if m >= 2, j > from, !s[j - 1].isWhitespace { return j + m - 2 }
        j += m
        continue
      }
      j += 1
    }
    return nil
  }

  struct LinkParse {
    var textEnd: Int
    var destination: String
    var after: Int
  }

  /// Parses `[text](dest "title")` whose `[` is at `open`.
  func link(at open: Int, end: Int) -> LinkParse? {
    var depth = 1
    var j = open + 1
    var textEnd: Int?
    while j < end {
      let ch = s[j]
      if ch == "\\" { j += 2; continue }
      if ch == "`" {
        j = codeSpanEnd(at: j, end: end) ?? (j + runLength(of: "`", at: j, end: end))
        continue
      }
      if ch == "[" { depth += 1 } else if ch == "]" {
        depth -= 1
        if depth == 0 { textEnd = j; break }
      }
      j += 1
    }
    guard let close = textEnd, close + 1 < end, s[close + 1] == "(" else { return nil }

    var k = close + 2
    while k < end, s[k] == " " || s[k] == "\t" { k += 1 }
    var destination = ""
    if k < end, s[k] == "<" {
      k += 1
      while k < end, s[k] != ">", s[k] != "\n" {
        if s[k] == "\\", k + 1 < end, isPunctuation(s[k + 1]) { k += 1 }
        destination.append(s[k])
        k += 1
      }
      guard k < end, s[k] == ">" else { return nil }
      k += 1
    } else {
      var parens = 0
      while k < end {
        let ch = s[k]
        if ch == "\\", k + 1 < end, isPunctuation(s[k + 1]) {
          destination.append(s[k + 1])
          k += 2
          continue
        }
        if ch == " " || ch == "\t" || ch == "\n" { break }
        if ch == "(" { parens += 1 }
        if ch == ")" {
          if parens == 0 { break }
          parens -= 1
        }
        destination.append(ch)
        k += 1
      }
    }
    while k < end, s[k] == " " || s[k] == "\t" || s[k] == "\n" { k += 1 }
    if k < end, s[k] == "\"" || s[k] == "'" || s[k] == "(" {
      let closeQuote: Character = s[k] == "(" ? ")" : s[k]
      k += 1
      while k < end, s[k] != closeQuote {
        if s[k] == "\\" { k += 1 }
        k += 1
      }
      guard k < end else { return nil }
      k += 1
      while k < end, s[k] == " " || s[k] == "\t" || s[k] == "\n" { k += 1 }
    }
    guard k < end, s[k] == ")" else { return nil }
    return LinkParse(textEnd: close, destination: destination, after: k + 1)
  }

  private func autolink(at open: Int, end: Int) -> (String, Int)? {
    var j = open + 1
    var content = ""
    while j < end, s[j] != ">" {
      if s[j].isWhitespace || s[j] == "<" { return nil }
      content.append(s[j])
      j += 1
    }
    guard j < end, !content.isEmpty else { return nil }
    if let colon = content.firstIndex(of: ":") {
      let scheme = content[..<colon]
      if scheme.count >= 2, scheme.count <= 32, scheme.first?.isLetter == true,
        scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+.-".contains($0)) }),
        content.index(after: colon) < content.endIndex
      {
        return (content, j + 1)
      }
    }
    if let at = content.firstIndex(of: "@"), at != content.startIndex,
      content[content.index(after: at)...].contains(".")
    {
      return ("mailto:" + content, j + 1)
    }
    return nil
  }
}
