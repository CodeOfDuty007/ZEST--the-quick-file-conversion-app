import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import ZestCore

/// Renders every page of a PDF to an image (150 DPI) through PDFKit and ImageIO.
/// A one-page PDF produces `<name>.<ext>`; longer ones produce `<name> page 01.<ext>`…
public struct PDFRenderBackend: Backend {
  public let id = "pdf-render"

  public init() {}

  /// Pixels per PDF point (150 DPI).
  static let renderScale = 150.0 / 72.0
  /// The longest side of a rendered page never exceeds this many pixels.
  static let maxSide = 8000.0

  private static let lossyOutputs: Set<UTType> = [.jpeg, .heic, .webP]

  public func capabilities() -> [Capability] {
    let writable = Set(
      ((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []).compactMap { UTType($0) }
    ).intersection(ImageIOBackend.userFacingOutputs)
    return writable.map { output in
      Capability(
        backendID: id,
        input: [.pdf],
        output: output,
        operation: .convert,
        quality: 85,
        speed: 60,
        isNative: true,
        isLosslessOutput: output == .png,
        params: Self.lossyOutputs.contains(output)
          ? [ParamSpec(key: "quality", label: "Quality", kind: .range(1, 100), defaultValue: "85")]
          : []
      )
    }
  }

  public func run(_ job: JobSpec, progress: Progress) async throws -> [URL] {
    guard let document = PDFDocument(url: job.input), document.pageCount > 0 else {
      throw BackendError.unreadable(job.input)
    }
    let output = job.capability.output
    let ext = Formats.fileExtension(for: output)
    let name = job.input.deletingPathExtension().lastPathComponent
    let count = document.pageCount
    let width = String(count).count

    var options: [CFString: Any] = [:]
    if Self.lossyOutputs.contains(output) {
      let percent = Double(job.params["quality"] ?? "85") ?? 85
      options[kCGImageDestinationLossyCompressionQuality] = min(max(percent, 1), 100) / 100
    }

    progress.totalUnitCount = Int64(count)
    var outputs: [URL] = []
    for index in 0..<count {
      try Task.checkCancellation()
      let fileName: String
      if count == 1 {
        fileName = "\(name).\(ext)"
      } else {
        let number = String(index + 1)
        let padded = String(repeating: "0", count: max(0, width - number.count)) + number
        fileName = "\(name) page \(padded).\(ext)"
      }
      let target = job.outputDirectory.appendingPathComponent(fileName)
      guard let page = document.page(at: index), let image = Self.render(page) else {
        throw BackendError.encodeFailed(fileName)
      }
      guard
        let destination = CGImageDestinationCreateWithURL(
          target as CFURL, output.identifier as CFString, 1, nil)
      else { throw BackendError.encodeFailed(fileName) }
      CGImageDestinationAddImage(destination, image, options as CFDictionary)
      guard CGImageDestinationFinalize(destination) else {
        throw BackendError.encodeFailed(fileName)
      }
      outputs.append(target)
      progress.completedUnitCount = Int64(index + 1)
    }
    return outputs
  }

  static func render(_ page: PDFPage) -> CGImage? {
    var box = page.bounds(for: .mediaBox)
    if page.rotation % 180 != 0 { box = CGRect(x: 0, y: 0, width: box.height, height: box.width) }
    guard box.width > 0, box.height > 0 else { return nil }
    var scale = renderScale
    let longest = max(box.width, box.height) * scale
    if longest > maxSide { scale *= maxSide / longest }
    let width = max(1, Int((box.width * scale).rounded()))
    let height = max(1, Int((box.height * scale).rounded()))
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.scaleBy(x: scale, y: scale)
    page.draw(with: .mediaBox, to: context)
    return context.makeImage()
  }
}
