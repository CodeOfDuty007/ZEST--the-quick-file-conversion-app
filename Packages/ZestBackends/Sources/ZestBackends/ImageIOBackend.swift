import Foundation
import ImageIO
import UniformTypeIdentifiers
import ZestCore

public enum BackendError: Error, LocalizedError {
  case unreadable(URL)
  case encodeFailed(String)
  case processFailed(status: Int32, stderr: String)

  public var errorDescription: String? {
    switch self {
    case .unreadable(let url): return "\(url.lastPathComponent) could not be read."
    case .encodeFailed(let name): return "Could not write \(name)."
    case .processFailed(let status, let stderr):
      let tail = stderr.split(separator: "\n").suffix(3).joined(separator: "\n")
      return "Converter exited with status \(status). \(tail)"
    }
  }
}

/// Image conversion through ImageIO. The format list comes from what this Mac's
/// ImageIO can actually read and write, so it differs per macOS version (Phase 0).
public struct ImageIOBackend: Backend {
  public let id = "imageio"

  public init() {}

  private static let losslessOutputs: Set<UTType> = [.png, .tiff]
  private static let lossyOutputs: Set<UTType> = [.jpeg, .heic, .webP]

  /// ImageIO can write dozens of niche formats (PSD, ICNS, EXR, PVR…). Only these
  /// belong on a wheel capped at eight wedges.
  static let userFacingOutputs: Set<UTType> = [
    .jpeg, .png, .heic, .tiff, .gif, .bmp, .webP, Formats.avif,
  ]

  public func capabilities() -> [Capability] {
    let readable = Self.types(from: CGImageSourceCopyTypeIdentifiers())
    let writable = Self.types(from: CGImageDestinationCopyTypeIdentifiers())
      .intersection(Self.userFacingOutputs)
    return writable.map { output in
      Capability(
        backendID: id,
        input: readable,
        output: output,
        quality: Self.losslessOutputs.contains(output) ? 95 : 90,
        speed: 80,
        isNative: true,
        isLosslessOutput: Self.losslessOutputs.contains(output),
        params: Self.lossyOutputs.contains(output)
          ? [ParamSpec(key: "quality", label: "Quality", kind: .range(1, 100), defaultValue: "85")]
          : []
      )
    }
  }

  private static func types(from identifiers: CFArray?) -> Set<UTType> {
    let ids = (identifiers as? [String]) ?? []
    return Set(ids.compactMap { UTType($0) }.filter { $0.conforms(to: .image) && $0 != .pdf })
  }

  public func run(_ job: JobSpec, progress: Progress) async throws -> [URL] {
    guard let source = CGImageSourceCreateWithURL(job.input as CFURL, nil) else {
      throw BackendError.unreadable(job.input)
    }
    let output = job.capability.output
    let ext = Formats.fileExtension(for: output)
    let name = job.input.deletingPathExtension().lastPathComponent
    let target = job.outputDirectory.appendingPathComponent("\(name).\(ext)")

    // Only GIF keeps every frame; other targets take the first image.
    let frames = output == .gif ? max(1, CGImageSourceGetCount(source)) : 1
    guard
      let destination = CGImageDestinationCreateWithURL(
        target as CFURL, output.identifier as CFString, frames, nil)
    else { throw BackendError.encodeFailed(target.lastPathComponent) }

    var options: [CFString: Any] = [:]
    if Self.lossyOutputs.contains(output) {
      let percent = Double(job.params["quality"] ?? "85") ?? 85
      options[kCGImageDestinationLossyCompressionQuality] = min(max(percent, 1), 100) / 100
    }

    progress.totalUnitCount = Int64(frames)
    for index in 0..<frames {
      CGImageDestinationAddImageFromSource(destination, source, index, options as CFDictionary)
      progress.completedUnitCount = Int64(index + 1)
    }
    guard CGImageDestinationFinalize(destination) else {
      throw BackendError.encodeFailed(target.lastPathComponent)
    }
    return [target]
  }
}
