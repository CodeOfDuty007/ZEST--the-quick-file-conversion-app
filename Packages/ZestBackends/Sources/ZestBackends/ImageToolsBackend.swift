import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import ZestCore

/// Image tools on ImageIO and Core Graphics: compress to a size target, strip metadata,
/// and build a collage. All native.
public struct ImageToolsBackend: ToolBackend {
  public let id = "image-tools"

  public init() {}

  private static let compressible: Set<UTType> = [.jpeg, .heic, .png]
  private static let strippable: Set<UTType> = [.jpeg, .heic, .png, .tiff]
  public static let percents = [25, 50, 75]

  public func capabilities() -> [Capability] { [] }

  public func tools() -> [ToolSpec] {
    var tools = Self.percents.map { percent in
      ToolSpec(
        id: "compress.image.\(percent)", backendID: id, root: .compress, title: "\(percent)%",
        symbol: "arrow.down.right.and.arrow.up.left", accepts: Self.compressible,
        params: ["percent": "\(percent)"], nameSuffix: " compressed")
    }
    tools.append(
      ToolSpec(
        id: "strip.image", backendID: id, root: .files, title: "Metadata", symbol: "eye.slash",
        accepts: Self.strippable, nameSuffix: " stripped"))
    tools.append(
      ToolSpec(
        id: "collage", backendID: id, root: .edit, title: "Collage",
        symbol: "square.grid.2x2", shape: .group(minimum: 2), accepts: [.image],
        nameSuffix: " collage", groupOutput: .jpeg))
    return tools
  }

  public func run(_ job: JobSpec, progress: Progress) async throws -> [URL] { [] }

  public func runTool(_ job: ToolJob, progress: Progress) async throws -> ToolResult {
    switch job.tool.id {
    case let id where id.hasPrefix("compress.image."):
      return try compress(job, progress: progress)
    case "strip.image":
      return try strip(job, progress: progress)
    case "collage":
      return try collage(job)
    default:
      throw ZestError.backendMissing(job.tool.id)
    }
  }

  // MARK: Compress

  private func compress(_ job: ToolJob, progress: Progress) throws -> ToolResult {
    let percent = Double(job.tool.params["percent"] ?? "50") ?? 50
    progress.totalUnitCount = Int64(job.inputs.count)
    var outputs: [ToolOutput] = []
    var skipped: [ToolSkip] = []

    for (index, input) in job.inputs.enumerated() {
      try Task.checkCancellation()
      defer { progress.completedUnitCount += 1 }
      guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
        let uti = CGImageSourceGetType(source).flatMap({ UTType($0 as String) })
      else { throw BackendError.unreadable(input) }

      // Re-encoding keeps only the first frame, which would silently flatten an animation.
      if CGImageSourceGetCount(source) > 1 {
        skipped.append(ToolSkip(source: index, reason: "Animated images are not compressed"))
        continue
      }

      let originalSize = Self.fileSize(input)
      let target = Int(Double(originalSize) * percent / 100)
      guard let data = Self.encodeWithin(source: source, type: uti, targetBytes: target) else {
        skipped.append(ToolSkip(source: index, reason: "Could not compress"))
        continue
      }
      guard data.count < originalSize else {
        skipped.append(ToolSkip(source: index, reason: "Already small"))
        continue
      }
      // A percentage is a promise; do not report success for a file that missed it.
      guard data.count <= target else {
        skipped.append(
          ToolSkip(source: index, reason: "Can't reach \(Int(percent))% without ruining it"))
        continue
      }
      let stem = input.deletingPathExtension().lastPathComponent
      let out = job.outputDirectory.appendingPathComponent(
        "\(index)-\(stem).\(Formats.fileExtension(for: uti))")
      try data.write(to: out)
      outputs.append(ToolOutput(url: out, source: index))
    }
    return ToolResult(outputs: outputs, skipped: skipped)
  }

  /// Finds the best encoding at or under `targetBytes`. Lossy types search quality; if even
  /// the lowest quality is too big, or the type is lossless, the image is scaled down.
  static func encodeWithin(source: CGImageSource, type: UTType, targetBytes: Int) -> Data? {
    let lossy = type == .jpeg || type == .heic
    var best: Data?

    var scale = lossy ? 1.0 : 0.9
    for _ in 0..<8 {
      if lossy {
        // Quality is searched at this scale; keep the largest quality that fits.
        var low = 0.05, high = 0.95
        var fit: Data?
        for _ in 0..<7 {
          let mid = (low + high) / 2
          guard let data = encode(source: source, type: type, quality: mid, scale: scale) else {
            return best
          }
          if data.count <= targetBytes {
            fit = data
            low = mid
          } else {
            high = mid
          }
        }
        if let fit { return fit }
        if let floor = encode(source: source, type: type, quality: 0.05, scale: scale) {
          if best == nil || floor.count < best!.count { best = floor }
        }
      } else if let data = encode(source: source, type: type, quality: 1, scale: scale) {
        if data.count <= targetBytes { return data }
        if best == nil || data.count < best!.count { best = data }
      }
      scale *= 0.8
    }
    return best
  }

  static func encode(source: CGImageSource, type: UTType, quality: Double, scale: Double) -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)
    else { return nil }

    var options: [CFString: Any] = [:]
    if type == .jpeg || type == .heic { options[kCGImageDestinationLossyCompressionQuality] = quality }

    if scale >= 0.999 {
      // Unscaled: copy the image with its metadata and orientation intact.
      CGImageDestinationAddImageFromSource(destination, source, 0, options as CFDictionary)
    } else {
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
      let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
      let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
      let thumbnail: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: max(Int(Double(max(width, height)) * scale), 16),
      ]
      guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnail as CFDictionary)
      else { return nil }
      // The pixels are already upright, so the orientation tag must not be applied twice.
      var carried = properties
      carried[kCGImagePropertyOrientation] = 1
      for (key, value) in options { carried[key] = value }
      CGImageDestinationAddImage(destination, image, carried as CFDictionary)
    }
    return CGImageDestinationFinalize(destination) ? data as Data : nil
  }

  private static func fileSize(_ url: URL) -> Int {
    (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
  }

  // MARK: Strip metadata

  private func strip(_ job: ToolJob, progress: Progress) throws -> ToolResult {
    progress.totalUnitCount = Int64(job.inputs.count)
    var outputs: [ToolOutput] = []
    var skipped: [ToolSkip] = []
    for (index, input) in job.inputs.enumerated() {
      try Task.checkCancellation()
      defer { progress.completedUnitCount += 1 }
      guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
        let uti = CGImageSourceGetType(source)
      else { throw BackendError.unreadable(input) }
      let stem = input.deletingPathExtension().lastPathComponent
      let ext = UTType(uti as String).map(Formats.fileExtension(for:)) ?? input.pathExtension
      let out = job.outputDirectory.appendingPathComponent("\(index)-\(stem).\(ext)")
      do {
        try Self.stripMetadata(source: source, type: uti, to: out)
      } catch StripError.animated {
        skipped.append(ToolSkip(source: index, reason: "Animated images cannot be stripped yet"))
        continue
      }
      outputs.append(ToolOutput(url: out, source: index))
    }
    return ToolResult(outputs: outputs, skipped: skipped)
  }

  enum StripError: Error { case animated }

  /// Removes EXIF, GPS, XMP and maker data. The orientation tag is kept (or baked into the
  /// pixels) so a phone photo does not turn sideways.
  static func stripMetadata(source: CGImageSource, type: CFString, to url: URL) throws {
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let orientation = (properties?[kCGImagePropertyOrientation] as? UInt32) ?? 1

    // Lossless path: rewrite the container with empty metadata and no recompression.
    if let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) {
      // Start from empty metadata and put back only the orientation.
      let metadata = CGImageMetadataCreateMutable()
      if orientation != 1 {
        CGImageMetadataSetValueWithPath(
          metadata, nil, "tiff:Orientation" as CFString, NSNumber(value: orientation))
      }
      let options: [CFString: Any] = [
        kCGImageDestinationMetadata: metadata,
        kCGImageDestinationMergeMetadata: false,
        kCGImageMetadataShouldExcludeGPS: true,
      ]
      var error: Unmanaged<CFError>?
      if CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error),
        !containsPersonalMetadata(at: url)
      {
        return
      }
    }

    // Fallback for containers that cannot be copied losslessly: re-encode upright pixels
    // with no properties at all.
    try? FileManager.default.removeItem(at: url)
    // Re-encoding keeps one frame; refuse rather than flatten an animation.
    if CGImageSourceGetCount(source) > 1 { throw StripError.animated }
    guard let image = orientedImage(from: source),
      let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil)
    else { throw BackendError.encodeFailed(url.lastPathComponent) }
    let quality: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
    CGImageDestinationAddImage(destination, image, quality as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      throw BackendError.encodeFailed(url.lastPathComponent)
    }
  }

  /// Reads the result back. Some containers (PNG text chunks, XMP) keep data that the lossless
  /// copy does not remove, and a tool called "strip" must never leave a location behind.
  static func containsPersonalMetadata(at url: URL) -> Bool {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else { return true }

    if properties[kCGImagePropertyGPSDictionary] != nil { return true }
    if properties[kCGImagePropertyIPTCDictionary] != nil { return true }

    let identifying: [CFString] = [
      kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFArtist,
      kCGImagePropertyTIFFSoftware, kCGImagePropertyTIFFCopyright,
      kCGImagePropertyTIFFHostComputer, kCGImagePropertyTIFFDocumentName,
      kCGImagePropertyTIFFImageDescription,
    ]
    if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
      identifying.contains(where: { tiff[$0] != nil })
    {
      return true
    }

    // Structural EXIF entries are harmless; anything else (comments, serials, dates) is not.
    let structural: Set<CFString> = [
      kCGImagePropertyExifColorSpace, kCGImagePropertyExifPixelXDimension,
      kCGImagePropertyExifPixelYDimension, kCGImagePropertyExifVersion,
      kCGImagePropertyExifComponentsConfiguration, kCGImagePropertyExifFlashPixVersion,
    ]
    if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
      exif.keys.contains(where: { !structural.contains($0) })
    {
      return true
    }
    if let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any],
      png[kCGImagePropertyPNGDescription] != nil || png[kCGImagePropertyPNGAuthor] != nil
        || png[kCGImagePropertyPNGSoftware] != nil || png[kCGImagePropertyPNGCreationTime] != nil
    {
      return true
    }
    return false
  }

  private static func orientedImage(from source: CGImageSource) -> CGImage? {
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
    let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1),
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }

  // MARK: Collage

  private func collage(_ job: ToolJob) throws -> ToolResult {
    let images = try job.inputs.map { url -> CGImage in
      guard let image = OrientedImage.load(url) else { throw BackendError.unreadable(url) }
      return image
    }
    let columns = Int(Double(images.count).squareRoot().rounded(.up))
    let rows = Int((Double(images.count) / Double(columns)).rounded(.up))
    let cell = 800, gap = 16
    let width = columns * cell + (columns + 1) * gap
    let height = rows * cell + (rows + 1) * gap

    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { throw BackendError.encodeFailed("collage") }
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.interpolationQuality = .high

    for (index, image) in images.enumerated() {
      let column = index % columns
      let row = index / columns
      let x = gap + column * (cell + gap)
      let y = height - (gap + (row + 1) * cell + row * gap)
      let frame = CGRect(x: x, y: y, width: cell, height: cell)

      // Fill the cell, cropping the overflow, so every picture is the same size.
      let scale = max(Double(cell) / Double(image.width), Double(cell) / Double(image.height))
      let drawn = CGSize(width: Double(image.width) * scale, height: Double(image.height) * scale)
      context.saveGState()
      context.clip(to: frame)
      context.draw(
        image,
        in: CGRect(
          x: frame.midX - drawn.width / 2, y: frame.midY - drawn.height / 2,
          width: drawn.width, height: drawn.height))
      context.restoreGState()
    }

    guard let result = context.makeImage() else { throw BackendError.encodeFailed("collage") }
    let out = job.outputDirectory.appendingPathComponent("collage.jpg")
    guard
      let destination = CGImageDestinationCreateWithURL(
        out as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    else { throw BackendError.encodeFailed("collage") }
    CGImageDestinationAddImage(
      destination, result, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw BackendError.encodeFailed("collage") }
    return ToolResult(outputs: [ToolOutput(url: out, source: nil)])
  }
}
