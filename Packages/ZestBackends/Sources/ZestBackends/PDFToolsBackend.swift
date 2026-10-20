import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import ZestCore

/// PDF tools on PDFKit and Core Graphics: merge, images to PDF, split, pages to images,
/// and metadata stripping. All native.
public struct PDFToolsBackend: ToolBackend {
  public let id = "pdf-tools"

  public init() {}

  /// Pixels per PDF point when rendering pages to images (150 DPI).
  static let renderScale = 150.0 / 72.0

  public func capabilities() -> [Capability] { [] }

  public func tools() -> [ToolSpec] {
    ImageToolsBackend.percents.map { percent in
      ToolSpec(
        id: "compress.pdf.\(percent)", backendID: id, root: .compress, title: "\(percent)%",
        symbol: "arrow.down.right.and.arrow.up.left", accepts: [.pdf],
        params: ["percent": "\(percent)"], nameSuffix: " compressed")
    } + [
      ToolSpec(
        id: "pdf.merge", backendID: id, root: .files, title: "Merge", symbol: "doc.on.doc",
        shape: .group(minimum: 2), accepts: [.pdf], nameSuffix: " merged", groupOutput: .pdf),
      ToolSpec(
        id: "images.to.pdf", backendID: id, root: .files, title: "To PDF",
        symbol: "photo.on.rectangle", shape: .group(minimum: 2), accepts: [.image],
        nameSuffix: " combined", groupOutput: .pdf),
      ToolSpec(
        id: "pdf.split", backendID: id, root: .files, title: "Split",
        symbol: "square.split.2x1", shape: .fanOut, accepts: [.pdf]),
      ToolSpec(
        id: "pdf.pages.images", backendID: id, root: .files, title: "Pages",
        symbol: "photo.stack", shape: .fanOut, accepts: [.pdf]),
      ToolSpec(
        id: "strip.pdf", backendID: id, root: .files, title: "Metadata", symbol: "eye.slash",
        accepts: [.pdf], nameSuffix: " stripped"),
    ]
  }

  public func run(_ job: JobSpec, progress: Progress) async throws -> [URL] { [] }

  public func runTool(_ job: ToolJob, progress: Progress) async throws -> ToolResult {
    switch job.tool.id {
    case let id where id.hasPrefix("compress.pdf."): return try compress(job)
    case "pdf.merge": return try merge(job)
    case "images.to.pdf": return try imagesToPDF(job)
    case "pdf.split": return try split(job)
    case "pdf.pages.images": return try pagesToImages(job)
    case "strip.pdf": return try strip(job)
    default: throw ZestError.backendMissing(job.tool.id)
    }
  }

  private func open(_ url: URL) throws -> PDFDocument {
    guard let document = PDFDocument(url: url), document.pageCount > 0 else {
      throw BackendError.unreadable(url)
    }
    return document
  }

  private func merge(_ job: ToolJob) throws -> ToolResult {
    let merged = PDFDocument()
    for url in job.inputs {
      try Task.checkCancellation()
      let document = try open(url)
      for index in 0..<document.pageCount {
        guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
        merged.insert(page, at: merged.pageCount)
      }
    }
    let out = job.outputDirectory.appendingPathComponent("merged.pdf")
    guard merged.write(to: out) else { throw BackendError.encodeFailed(out.lastPathComponent) }
    return ToolResult(outputs: [ToolOutput(url: out, source: nil)])
  }

  /// One page per image, each page the size of its (upright) image.
  private func imagesToPDF(_ job: ToolJob) throws -> ToolResult {
    let out = job.outputDirectory.appendingPathComponent("combined.pdf")
    var first = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let context = CGContext(out as CFURL, mediaBox: &first, nil) else {
      throw BackendError.encodeFailed(out.lastPathComponent)
    }
    for url in job.inputs {
      try Task.checkCancellation()
      guard let image = OrientedImage.load(url) else { throw BackendError.unreadable(url) }
      var box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
      let pageInfo = [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)]
      context.beginPDFPage(pageInfo as CFDictionary)
      context.draw(image, in: box)
      context.endPDFPage()
    }
    context.closePDF()
    return ToolResult(outputs: [ToolOutput(url: out, source: nil)])
  }

  private func split(_ job: ToolJob) throws -> ToolResult {
    var outputs: [ToolOutput] = []
    for (sourceIndex, url) in job.inputs.enumerated() {
      let document = try open(url)
      let name = url.deletingPathExtension().lastPathComponent
      let folder = job.outputDirectory.appendingPathComponent("\(sourceIndex)", isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      for index in 0..<document.pageCount {
        try Task.checkCancellation()
        guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
        let single = PDFDocument()
        single.insert(page, at: 0)
        let out = folder.appendingPathComponent("\(name) page \(index + 1).pdf")
        guard single.write(to: out) else { throw BackendError.encodeFailed(out.lastPathComponent) }
        outputs.append(ToolOutput(url: out, source: sourceIndex))
      }
    }
    return ToolResult(outputs: outputs)
  }

  private func pagesToImages(_ job: ToolJob) throws -> ToolResult {
    var outputs: [ToolOutput] = []
    for (sourceIndex, url) in job.inputs.enumerated() {
      let document = try open(url)
      let name = url.deletingPathExtension().lastPathComponent
      let folder = job.outputDirectory.appendingPathComponent("\(sourceIndex)", isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      for index in 0..<document.pageCount {
        try Task.checkCancellation()
        guard let page = document.page(at: index), let image = render(page) else {
          throw BackendError.encodeFailed("page \(index + 1)")
        }
        let out = folder.appendingPathComponent("\(name) page \(index + 1).png")
        guard
          let destination = CGImageDestinationCreateWithURL(
            out as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw BackendError.encodeFailed(out.lastPathComponent) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
          throw BackendError.encodeFailed(out.lastPathComponent)
        }
        outputs.append(ToolOutput(url: out, source: sourceIndex))
      }
    }
    return ToolResult(outputs: outputs)
  }

  private func render(_ page: PDFPage) -> CGImage? {
    let box = page.bounds(for: .mediaBox)
    let width = Int((box.width * Self.renderScale).rounded())
    let height = Int((box.height * Self.renderScale).rounded())
    guard width > 0, height > 0,
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.scaleBy(x: Self.renderScale, y: Self.renderScale)
    page.draw(with: .mediaBox, to: context)
    return context.makeImage()
  }

  private func strip(_ job: ToolJob) throws -> ToolResult {
    var outputs: [ToolOutput] = []
    for (index, url) in job.inputs.enumerated() {
      let document = try open(url)
      document.documentAttributes = [:]
      let out = job.outputDirectory.appendingPathComponent("\(index)-\(url.lastPathComponent)")
      guard document.write(to: out) else { throw BackendError.encodeFailed(out.lastPathComponent) }
      outputs.append(ToolOutput(url: out, source: index))
    }
    return ToolResult(outputs: outputs)
  }

  // MARK: Compress

  /// Shrinks to the chosen share of the original size by re-rendering every page as a
  /// JPEG, lowering resolution and quality until it fits. Text becomes part of the page
  /// image, so a file that cannot reach the target is skipped instead of ruined.
  private func compress(_ job: ToolJob) throws -> ToolResult {
    let percent = Double(job.tool.params["percent"] ?? "50") ?? 50
    var outputs: [ToolOutput] = []
    var skipped: [ToolSkip] = []
    for (index, url) in job.inputs.enumerated() {
      try Task.checkCancellation()
      let document = try open(url)
      // Compression flattens pages to images, so anything that would be lost is refused,
      // not dropped silently: selectable text, links and form fields, bookmarks.
      if let lost = Self.contentFlatteningWouldLose(document) {
        skipped.append(ToolSkip(source: index, reason: "Has \(lost) that compressing would remove"))
        continue
      }
      let original = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      let target = Int(Double(original) * percent / 100)
      guard let data = try Self.shrink(document, targetBytes: target) else {
        skipped.append(ToolSkip(source: index, reason: "Can't reach \(Int(percent))% without ruining it"))
        continue
      }
      let out = job.outputDirectory.appendingPathComponent("\(index)-\(url.lastPathComponent)")
      try data.write(to: out)
      outputs.append(ToolOutput(url: out, source: index))
    }
    return ToolResult(outputs: outputs, skipped: skipped)
  }

  static func contentFlatteningWouldLose(_ document: PDFDocument) -> String? {
    if document.outlineRoot != nil { return "bookmarks" }
    for index in 0..<document.pageCount {
      guard let page = document.page(at: index) else { continue }
      if !page.annotations.isEmpty { return "links or annotations" }
      if !(page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return "selectable text"
      }
    }
    return nil
  }

  private static func shrink(_ document: PDFDocument, targetBytes: Int) throws -> Data? {
    for dpi in [150.0, 110, 80, 60, 45] {
      let scale = dpi / 72
      var pages: [(CGImage, CGRect)] = []
      for index in 0..<document.pageCount {
        try Task.checkCancellation()
        guard let page = document.page(at: index) else { continue }
        let box = page.bounds(for: .mediaBox)
        let width = max(Int((box.width * scale).rounded()), 1)
        let height = max(Int((box.height * scale).rounded()), 1)
        guard
          let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        page.draw(with: .mediaBox, to: context)
        guard let image = context.makeImage() else { return nil }
        pages.append((image, CGRect(origin: .zero, size: box.size)))
      }
      for quality in [0.7, 0.5, 0.35, 0.2] {
        try Task.checkCancellation()
        if let data = pdf(from: pages, quality: quality), data.count <= targetBytes { return data }
      }
    }
    return nil
  }

  private static func pdf(from pages: [(CGImage, CGRect)], quality: Double) -> Data? {
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data), let first = pages.first else { return nil }
    var firstBox = first.1
    guard let context = CGContext(consumer: consumer, mediaBox: &firstBox, nil) else { return nil }
    for (image, box) in pages {
      // Round-trip through JPEG so the PDF embeds compressed data, not raw pixels.
      let jpeg = NSMutableData()
      guard
        let destination = CGImageDestinationCreateWithData(
          jpeg, UTType.jpeg.identifier as CFString, 1, nil)
      else { return nil }
      CGImageDestinationAddImage(
        destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
      guard CGImageDestinationFinalize(destination),
        let source = CGImageSourceCreateWithData(jpeg, nil),
        let compressed = CGImageSourceCreateImageAtIndex(source, 0, nil)
      else { return nil }
      var mediaBox = box
      let info = [kCGPDFContextMediaBox as String: Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size)]
      context.beginPDFPage(info as CFDictionary)
      context.draw(compressed, in: box)
      context.endPDFPage()
    }
    context.closePDF()
    return data as Data
  }
}
