import Foundation

/// A run of text with its styling. A `\n` in `text` is a hard line break.
struct Inline: Sendable, Equatable {
  var text: String
  var bold = false
  var italic = false
  var strike = false
  var code = false
  var link: String?

  init(
    _ text: String, bold: Bool = false, italic: Bool = false, strike: Bool = false,
    code: Bool = false, link: String? = nil
  ) {
    self.text = text
    self.bold = bold
    self.italic = italic
    self.strike = strike
    self.code = code
    self.link = link
  }

  var styleKey: [Bool] { [bold, italic, strike, code] }
}

/// The format-neutral shape of a document. Every reader produces blocks and every writer
/// consumes them, so each input reaches each output through one model instead of N x M converters.
enum Block: Sendable, Equatable {
  case heading(Int, [Inline])
  case paragraph([Inline])
  /// Flat list entries; writers group neighbours into lists and nest by `depth`.
  case listItem(ordered: Bool, depth: Int, [Inline])
  case quote([Inline])
  case code(language: String?, text: String)
  case table(header: [[Inline]], rows: [[[Inline]]])
  /// `dataURI` is an inlined copy for HTML; Markdown and fallbacks use `src`.
  case image(alt: String, src: String, dataURI: String?)
  /// Audio or video that is referenced, not embedded.
  case media(video: Bool, name: String, src: String)
  case rule
}

struct Document: Sendable, Equatable {
  var title: String
  var blocks: [Block]
}

extension Inline {
  static func plain(_ text: String) -> [Inline] { text.isEmpty ? [] : [Inline(text)] }
}

// MARK: Markdown writer

enum MarkdownWriter {
  static func render(_ document: Document) -> String {
    var out = ""
    var previous: Block?
    var orderedCounters: [Int: Int] = [:]

    for block in document.blocks {
      if case .listItem(let ordered, let depth, _) = block {
        // Counters of deeper levels restart whenever a shallower item appears.
        orderedCounters = orderedCounters.filter { $0.key <= depth }
        if !ordered { orderedCounters[depth] = nil }
      } else {
        orderedCounters = [:]
      }

      let isListContinuation: Bool = {
        if case .listItem = block, case .listItem? = previous { return true }
        return false
      }()
      if previous != nil { out += isListContinuation ? "\n" : "\n\n" }

      switch block {
      case .heading(let level, let inlines):
        out += String(repeating: "#", count: min(max(level, 1), 6)) + " "
          + inlineText(inlines).replacingOccurrences(of: "\n", with: " ")
      case .paragraph(let inlines):
        out += guardBlockStart(inlineText(inlines))
      case .listItem(let ordered, let depth, let inlines):
        let marker: String
        if ordered {
          let n = (orderedCounters[depth] ?? 0) + 1
          orderedCounters[depth] = n
          marker = "\(n)."
        } else {
          marker = "-"
        }
        let indent = String(repeating: "  ", count: max(depth, 0))
        let body = inlineText(inlines).replacingOccurrences(of: "\n", with: "\n" + indent + "  ")
        out += indent + marker + " " + body
      case .quote(let inlines):
        out += inlineText(inlines).split(separator: "\n", omittingEmptySubsequences: false)
          .map { "> " + $0 }.joined(separator: "\n")
      case .code(let language, let text):
        let fence = String(repeating: "`", count: max(3, longestBacktickRun(in: text) + 1))
        out += fence + (language ?? "") + "\n" + text + (text.hasSuffix("\n") ? "" : "\n") + fence
      case .table(let header, let rows):
        out += tableText(header: header, rows: rows)
      case .image(let alt, let src, _):
        out += "![\(escape(alt, extra: "]"))](\(destination(src)))"
      case .media(_, let name, let src):
        out += "[\(escape(name, extra: "]"))](\(destination(src)))"
      case .rule:
        out += "---"
      }
      previous = block
    }
    return out + "\n"
  }

  private static func tableText(header: [[Inline]], rows: [[[Inline]]]) -> String {
    let columns = max(header.count, rows.map(\.count).max() ?? 0, 1)
    func cell(_ inlines: [Inline]?) -> String {
      (inlines.map { inlineText($0) } ?? "")
        .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "|", with: "\\|")
    }
    func line(_ cells: [[Inline]]) -> String {
      "| " + (0..<columns).map { cell($0 < cells.count ? cells[$0] : nil) }.joined(separator: " | ") + " |"
    }
    var lines = [line(header), "|" + String(repeating: " --- |", count: columns)]
    lines += rows.map(line)
    return lines.joined(separator: "\n")
  }

  /// A paragraph that happens to start like Markdown syntax must not turn into it.
  private static func guardBlockStart(_ text: String) -> String {
    guard let first = text.first else { return text }
    if "#>-+*=".contains(first) { return "\\" + text }
    var digits = 0
    for character in text {
      if character.isASCII, character.isNumber { digits += 1; continue }
      if digits > 0, character == "." || character == ")" { return "\\" + text }
      break
    }
    return text
  }

  private static func longestBacktickRun(in text: String) -> Int {
    var best = 0, run = 0
    for character in text {
      run = character == "`" ? run + 1 : 0
      best = max(best, run)
    }
    return best
  }

  private static func destination(_ src: String) -> String {
    let encoded =
      src.addingPercentEncoding(
        withAllowedCharacters: CharacterSet.urlPathAllowed.union(CharacterSet(charactersIn: ":?&=#%")))
      ?? src
    return encoded.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
  }

  static func escape(_ text: String, extra: String = "") -> String {
    var out = ""
    for character in text {
      if "\\`*_[]<>".contains(character) || extra.contains(character) { out.append("\\") }
      out.append(character)
    }
    return out
  }

  static func inlineText(_ inlines: [Inline]) -> String {
    var out = ""
    for inline in mergedRuns(inlines) {
      if inline.text.isEmpty { continue }
      if inline.code && !inline.text.contains("\n") {
        let fence = String(repeating: "`", count: longestBacktickRun(in: inline.text) + 1)
        let padded = inline.text.hasPrefix("`") || inline.text.hasSuffix("`") ? " \(inline.text) " : inline.text
        out += wrap(fence + padded + fence, inline)
        continue
      }
      // Markers must hug the text, so surrounding spaces stay outside them.
      let leading = inline.text.prefix { $0 == " " || $0 == "\t" }
      let trailing = inline.text.reversed().prefix { $0 == " " || $0 == "\t" }
      let core = inline.text.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
      if core.isEmpty { out += inline.text; continue }
      let escaped = escape(core).replacingOccurrences(of: "\n", with: "  \n")
      out += leading + wrap(escaped, inline) + String(trailing)
    }
    return out
  }

  private static func wrap(_ text: String, _ inline: Inline) -> String {
    var result = text
    if inline.strike { result = "~~\(result)~~" }
    if inline.bold && inline.italic { result = "***\(result)***" }
    else if inline.bold { result = "**\(result)**" }
    else if inline.italic { result = "*\(result)*" }
    if let link = inline.link { result = "[\(result)](\(destination(link)))" }
    return result
  }

  /// Joins neighbours with the same style so `**a****b**` never appears.
  static func mergedRuns(_ inlines: [Inline]) -> [Inline] {
    var merged: [Inline] = []
    for inline in inlines {
      if var last = merged.last, last.styleKey == inline.styleKey, last.link == inline.link {
        last.text += inline.text
        merged[merged.count - 1] = last
      } else {
        merged.append(inline)
      }
    }
    return merged
  }
}

// MARK: HTML writer

enum HTMLWriter {
  static func render(_ document: Document) -> String {
    var body = ""
    var openLists: [Bool] = []  // ordered flag per open nesting level

    func closeLists(downTo depth: Int) {
      while openLists.count > depth {
        body += "</li>\n" + String(repeating: "  ", count: openLists.count - 1)
        body += openLists.removeLast() ? "</ol>\n" : "</ul>\n"
      }
    }

    for block in document.blocks {
      if case .listItem(let ordered, let rawDepth, let inlines) = block {
        let depth = min(max(rawDepth, 0), openLists.count)  // never skip a level
        if openLists.count > depth + 1 { closeLists(downTo: depth + 1) }
        if openLists.count == depth + 1 {
          if openLists[depth] == ordered {
            body += "</li>\n"
          } else {
            closeLists(downTo: depth)
          }
        }
        if openLists.count == depth {
          body += String(repeating: "  ", count: depth) + (ordered ? "<ol>\n" : "<ul>\n")
          openLists.append(ordered)
        }
        body += String(repeating: "  ", count: depth + 1) + "<li>" + inlineHTML(inlines)
        continue
      }
      closeLists(downTo: 0)

      switch block {
      case .heading(let level, let inlines):
        let n = min(max(level, 1), 6)
        body += "<h\(n)>\(inlineHTML(inlines))</h\(n)>\n"
      case .paragraph(let inlines):
        body += "<p>\(inlineHTML(inlines))</p>\n"
      case .quote(let inlines):
        body += "<blockquote><p>\(inlineHTML(inlines))</p></blockquote>\n"
      case .code(let language, let text):
        let cls = language.map { " class=\"language-\(escape($0))\"" } ?? ""
        body += "<pre><code\(cls)>\(escape(text))</code></pre>\n"
      case .table(let header, let rows):
        body += "<table>\n<thead><tr>"
        body += header.map { "<th>\(inlineHTML($0))</th>" }.joined()
        body += "</tr></thead>\n<tbody>\n"
        for row in rows {
          body += "<tr>" + row.map { "<td>\(inlineHTML($0))</td>" }.joined() + "</tr>\n"
        }
        body += "</tbody>\n</table>\n"
      case .image(let alt, let src, let dataURI):
        let source = dataURI ?? src
        if let safe = safeURL(source, allowData: true) {
          body += "<figure><img src=\"\(escape(safe))\" alt=\"\(escape(alt))\"></figure>\n"
        } else {
          body += "<p>\(escape(alt))</p>\n"
        }
      case .media(let video, let name, let src):
        let tag = video ? "video" : "audio"
        if let safe = safeURL(src, allowData: false) {
          body += "<\(tag) controls src=\"\(escape(safe))\">\(escape(name))</\(tag)>\n"
        } else {
          body += "<p>\(escape(name))</p>\n"
        }
      case .rule:
        body += "<hr>\n"
      case .listItem:
        break
      }
    }
    closeLists(downTo: 0)

    return """
      <!doctype html>
      <html lang="en">
      <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>\(escape(document.title))</title>
      <style>
      body { font: 16px/1.6 -apple-system, system-ui, sans-serif; max-width: 46rem; margin: 2rem auto; padding: 0 1rem; color: #1d1d1f; }
      pre { background: #f5f5f7; padding: 1rem; overflow-x: auto; border-radius: 6px; }
      code { font-family: ui-monospace, Menlo, monospace; font-size: 0.9em; }
      table { border-collapse: collapse; } th, td { border: 1px solid #d2d2d7; padding: 0.35rem 0.7rem; text-align: left; }
      blockquote { margin-left: 0; padding-left: 1rem; border-left: 3px solid #d2d2d7; color: #515154; }
      img, video { max-width: 100%; height: auto; } figure { margin: 1rem 0; }
      @media (prefers-color-scheme: dark) { body { background: #1d1d1f; color: #f5f5f7; } pre { background: #2c2c2e; } th, td { border-color: #48484a; } }
      </style>
      </head>
      <body>
      \(body)</body>
      </html>

      """
  }

  static func inlineHTML(_ inlines: [Inline]) -> String {
    var out = ""
    for inline in MarkdownWriter.mergedRuns(inlines) {
      var piece = escape(inline.text).replacingOccurrences(of: "\n", with: "<br>\n")
      if inline.code { piece = "<code>\(piece)</code>" }
      if inline.strike { piece = "<s>\(piece)</s>" }
      if inline.italic { piece = "<em>\(piece)</em>" }
      if inline.bold { piece = "<strong>\(piece)</strong>" }
      if let link = inline.link, let safe = safeURL(link, allowData: false) {
        piece = "<a href=\"\(escape(safe))\">\(piece)</a>"
      }
      out += piece
    }
    return out
  }

  static func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
  }

  /// Source documents are untrusted: a `javascript:` link must not survive the conversion.
  static func safeURL(_ raw: String, allowData: Bool) -> String? {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = value.lowercased()
    if lower.hasPrefix("data:image/png") || lower.hasPrefix("data:image/jpeg")
      || lower.hasPrefix("data:image/gif")
    {
      return allowData ? value : nil
    }
    if let colon = lower.firstIndex(of: ":") {
      let scheme = String(lower[..<colon])
      // `foo:bar` with no slash before the colon is a scheme; anything else is a relative path.
      if !scheme.contains("/") && !scheme.contains("?") && !scheme.contains("#") {
        return ["http", "https", "mailto", "tel"].contains(scheme) ? value : nil
      }
    }
    return value.isEmpty ? nil : value
  }
}

extension Document {
  /// True when no block carries any text, so a conversion would write an empty file.
  var isEmpty: Bool {
    !blocks.contains { block in
      switch block {
      case .heading(_, let i), .paragraph(let i), .quote(let i), .listItem(_, _, let i):
        return !i.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      case .code(_, let t): return !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      case .table(let h, let rows): return !(h.isEmpty && rows.isEmpty)
      case .image, .media: return true
      case .rule: return true
      }
    }
  }
}
