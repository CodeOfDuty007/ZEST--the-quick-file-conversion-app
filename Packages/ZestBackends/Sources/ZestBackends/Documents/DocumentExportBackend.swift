import AppKit
import CoreText
import Foundation
import UniformTypeIdentifiers
import ZestCore

/// Writes documents out as PDF, Word, RTF and plain text, from the same block model the
/// Markdown and HTML writers use. With PDF as a lossless step, a document also reaches every
/// image format through the PDF renderer.
public struct DocumentExportBackend: Backend {
  public let id = "document-export"

  public init() {}

  static let docx = UTType("org.openxmlformats.wordprocessingml.document")

  /// Documents and text only: audio, video and pictures have their own conversions.
  static let inputs: Set<UTType> = {
    var set: Set<UTType> = [.pdf, .text, .rtf, .rtfd, .flatRTFD, .html]
    for id in ["org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc",
      "org.oasis-open.opendocument.text"]
    {
      if let type = UTType(id) { set.insert(type) }
    }
    return set
  }()

  public func capabilities() -> [Capability] {
    var outputs: [UTType] = [.pdf, .rtf, .plainText]
    if let docx = Self.docx { outputs.append(docx) }
    return outputs.map { output in
      Capability(
        backendID: id, input: Self.inputs, output: output, quality: 75, speed: 55, isNative: true,
        isLosslessOutput: output == .pdf)
    }
  }

  public func run(_ job: JobSpec, progress: Progress) async throws -> [URL] {
    let input = job.input
    guard let type = ContentSniffer.type(ofFileAt: input), let kind = DocumentBackend.kind(of: type),
      kind != .image, kind != .media
    else { throw BackendError.unreadable(input) }
    let document = try await DocumentBackend.load(input, type: type, kind: kind, embedImages: false)
    try Task.checkCancellation()

    let output = job.capability.output
    let data: Data?
    switch output {
    case .plainText:
      data = Data(PlainTextWriter.render(document).utf8)
    case .pdf:
      data = Self.pdf(AttributedBuilder.build(document))
    case .rtf:
      let text = AttributedBuilder.build(document)
      data = try? text.data(
        from: NSRange(location: 0, length: text.length),
        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    default:
      let text = AttributedBuilder.build(document)
      data = try? text.data(
        from: NSRange(location: 0, length: text.length),
        documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
    }
    let name = input.deletingPathExtension().lastPathComponent
    let target = job.outputDirectory.appendingPathComponent(
      "\(name).\(Formats.fileExtension(for: output))")
    guard let data, (try? data.write(to: target)) != nil else {
      throw BackendError.encodeFailed(target.lastPathComponent)
    }
    return [target]
  }

  /// US Letter pages with one inch margins; text flows onto as many pages as it needs.
  static func pdf(_ text: NSAttributedString) -> Data? {
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data) else { return nil }
    var media = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let context = CGContext(consumer: consumer, mediaBox: &media, nil) else { return nil }
    let setter = CTFramesetterCreateWithAttributedString(text)
    let area = CGPath(rect: CGRect(x: 72, y: 72, width: 468, height: 648), transform: nil)
    var location = 0
    repeat {
      context.beginPDFPage(nil)
      let frame = CTFramesetterCreateFrame(setter, CFRange(location: location, length: 0), area, nil)
      CTFrameDraw(frame, context)
      let shown = CTFrameGetVisibleStringRange(frame).length
      context.endPDFPage()
      if shown == 0 { break }
      location += shown
    } while location < text.length
    context.closePDF()
    return data as Data
  }
}

enum PlainTextWriter {
  static func render(_ document: Document) -> String {
    func text(_ inlines: [Inline]) -> String { inlines.map(\.text).joined() }
    var lines: [String] = []
    for block in document.blocks {
      switch block {
      case .heading(_, let inlines), .paragraph(let inlines), .quote(let inlines):
        lines.append(text(inlines)); lines.append("")
      case .listItem(let ordered, let depth, let inlines):
        lines.append(String(repeating: "  ", count: depth) + (ordered ? "- " : "• ") + text(inlines))
      case .code(_, let code):
        lines.append(code); lines.append("")
      case .table(let header, let rows):
        for row in [header] + rows { lines.append(row.map(text).joined(separator: "\t")) }
        lines.append("")
      case .image(let alt, _, _): lines.append(alt); lines.append("")
      case .media(_, let name, _): lines.append(name); lines.append("")
      case .rule: lines.append("----------"); lines.append("")
      }
    }
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
  }
}

enum AttributedBuilder {
  static func build(_ document: Document) -> NSAttributedString {
    let out = NSMutableAttributedString()
    let manager = NSFontManager.shared
    func font(_ size: CGFloat, bold: Bool = false, italic: Bool = false, mono: Bool = false) -> NSFont {
      var base = NSFont(name: mono ? "Menlo" : "Helvetica", size: size) ?? .systemFont(ofSize: size)
      if bold { base = manager.convert(base, toHaveTrait: .boldFontMask) }
      if italic { base = manager.convert(base, toHaveTrait: .italicFontMask) }
      return base
    }
    func runs(_ inlines: [Inline], size: CGFloat, forceBold: Bool = false) -> NSAttributedString {
      let result = NSMutableAttributedString()
      for inline in inlines {
        var attributes: [NSAttributedString.Key: Any] = [
          .font: font(size, bold: inline.bold || forceBold, italic: inline.italic, mono: inline.code)
        ]
        if inline.strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let link = inline.link, let safe = HTMLWriter.safeURL(link, allowData: false),
          let url = URL(string: safe)
        {
          attributes[.link] = url
        }
        result.append(NSAttributedString(string: inline.text, attributes: attributes))
      }
      return result
    }
    func paragraph(_ content: NSAttributedString, indent: CGFloat = 0, after: CGFloat = 8) {
      let style = NSMutableParagraphStyle()
      style.paragraphSpacing = after
      style.firstLineHeadIndent = indent
      style.headIndent = indent
      let line = NSMutableAttributedString(attributedString: content)
      line.append(NSAttributedString(string: "\n"))
      line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
      out.append(line)
    }

    for block in document.blocks {
      switch block {
      case .heading(let level, let inlines):
        let size: CGFloat = [24, 20, 16, 14, 13, 12][min(max(level, 1), 6) - 1]
        paragraph(runs(inlines, size: size, forceBold: true), after: 10)
      case .paragraph(let inlines), .quote(let inlines):
        paragraph(runs(inlines, size: 12))
      case .listItem(let ordered, let depth, let inlines):
        let marker = NSMutableAttributedString(string: ordered ? "– " : "• ", attributes: [.font: font(12)])
        marker.append(runs(inlines, size: 12))
        paragraph(marker, indent: CGFloat(depth + 1) * 18, after: 2)
      case .code(_, let code):
        paragraph(NSAttributedString(string: code, attributes: [.font: font(10.5, mono: true)]))
      case .table(let header, let rows):
        for row in [header] + rows {
          let line = NSMutableAttributedString()
          for (index, cell) in row.enumerated() {
            if index > 0 { line.append(NSAttributedString(string: "\t", attributes: [.font: font(12)])) }
            line.append(runs(cell, size: 12, forceBold: row == header))
          }
          paragraph(line, after: 2)
        }
      case .image(let alt, _, _):
        paragraph(runs([Inline(alt, italic: true)], size: 12))
      case .media(_, let name, _):
        paragraph(runs([Inline(name, italic: true)], size: 12))
      case .rule:
        paragraph(NSAttributedString(string: "———", attributes: [.font: font(12)]))
      }
    }
    return out
  }
}
