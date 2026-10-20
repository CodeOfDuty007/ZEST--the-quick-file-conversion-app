import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Reads an image into the document model: the picture itself, then any text found in it
/// by on-device OCR.
enum ImageReader {
  private struct Line {
    var text: String
    var box: CGRect  // normalized, origin bottom-left
  }

  static func read(url: URL, embed: Bool) throws -> Document {
    guard let image = OrientedImage.load(url) else { throw BackendError.unreadable(url) }
    let name = url.lastPathComponent
    var blocks: [Block] = [
      .image(alt: name, src: name, dataURI: embed ? dataURI(for: image) : nil)
    ]
    let text = ocrBlocks(for: image)
    blocks += text
    if text.isEmpty { blocks.append(.paragraph(Inline.plain("No text was found in this image."))) }
    return Document(title: url.deletingPathExtension().lastPathComponent, blocks: blocks)
  }

  static func ocrBlocks(for image: CGImage) -> [Block] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    if #available(macOS 13.0, *) { request.automaticallyDetectsLanguage = true }
    if #available(macOS 13.0, *) { request.revision = VNRecognizeTextRequestRevision3 }
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    do { try handler.perform([request]) } catch { return [] }

    let lines: [Line] = (request.results ?? []).compactMap { observation in
      guard let text = observation.topCandidates(1).first?.string
        .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
      else { return nil }
      return Line(text: text, box: observation.boundingBox)
    }
    return group(lines)
  }

  private static func group(_ input: [Line]) -> [Block] {
    guard !input.isEmpty else { return [] }
    let lines = input.sorted { $0.box.midY > $1.box.midY }
    let heights = lines.map(\.box.height).sorted()
    let median = heights[heights.count / 2]

    func isHeading(_ line: Line) -> Bool {
      line.box.height >= 1.4 * median && line.text.count <= 80
        && line.text.split(separator: " ").count <= 10
    }

    var blocks: [Block] = []
    var current: [Line] = []
    func flush() {
      guard !current.isEmpty else { return }
      blocks.append(.paragraph(Inline.plain(current.map(\.text).joined(separator: " "))))
      current = []
    }

    var previous: Line?
    for line in lines {
      if isHeading(line) {
        flush()
        blocks.append(.heading(2, Inline.plain(line.text)))
      } else {
        if let last = current.last {
          let gap = last.box.minY - line.box.maxY
          let lineHeight = max(last.box.height, line.box.height)
          let indent = abs(line.box.minX - last.box.minX)
          if gap > 0.6 * lineHeight || indent > 3 * lineHeight { flush() }
        } else if let previous, isHeading(previous) {
          // a paragraph after a heading starts fresh
        }
        current.append(line)
      }
      previous = line
    }
    flush()
    return blocks
  }

  private static func dataURI(for image: CGImage) -> String? {
    var image = image
    let longest = max(image.width, image.height)
    if longest > 1600 {
      let scale = 1600.0 / Double(longest)
      let w = max(1, Int((Double(image.width) * scale).rounded()))
      let h = max(1, Int((Double(image.height) * scale).rounded()))
      if let space = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
          data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      {
        context.interpolationQuality = .high
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        if let scaled = context.makeImage() { image = scaled }
      }
    }
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data, UTType.jpeg.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(
      destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return "data:image/jpeg;base64," + (data as Data).base64EncodedString()
  }
}
