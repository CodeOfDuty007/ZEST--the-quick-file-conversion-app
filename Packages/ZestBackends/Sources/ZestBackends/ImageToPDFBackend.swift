import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import ZestCore

/// Wraps an image in a single-page PDF using Core Graphics. Native, no extra engine.
public struct ImageToPDFBackend: Backend {
  public let id = "image-pdf"

  public init() {}

  private static let inputs: Set<UTType> = [.png, .jpeg, .heic, .tiff, .bmp, .gif, .webP]

  public func capabilities() -> [Capability] {
    [
      Capability(
        backendID: id, input: Self.inputs, output: .pdf, quality: 90, speed: 85, isNative: true)
    ]
  }

  public func run(_ job: JobSpec, progress: Progress) async throws -> [URL] {
    guard let image = OrientedImage.load(job.input) else {
      throw BackendError.unreadable(job.input)
    }

    let name = job.input.deletingPathExtension().lastPathComponent
    let target = job.outputDirectory.appendingPathComponent("\(name).pdf")

    // One PDF point per pixel keeps the page the same size the image reports.
    var box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    guard let context = CGContext(target as CFURL, mediaBox: &box, nil) else {
      throw BackendError.encodeFailed(target.lastPathComponent)
    }
    context.beginPDFPage(nil)
    context.draw(image, in: box)
    context.endPDFPage()
    context.closePDF()
    return [target]
  }
}
