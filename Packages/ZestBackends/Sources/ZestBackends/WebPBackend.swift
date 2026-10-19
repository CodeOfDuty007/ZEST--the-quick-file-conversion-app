import Foundation
import UniformTypeIdentifiers
import ZestCore

/// WebP output through libwebp's `cwebp`. ImageIO cannot write WebP on current macOS.
/// Until the static build lands in Vendor/, this uses a `cwebp` already on disk.
public struct WebPBackend: Backend {
  public let id = "webp"
  let executable: URL

  public init(executable: URL) { self.executable = executable }

  public static var searchPaths: [String] { Executables.candidates(for: "cwebp") }

  public static func detect(extraPaths: [String] = []) -> WebPBackend? {
    Executables.find("cwebp", extraPaths: extraPaths).map { WebPBackend(executable: $0) }
  }

  /// cwebp reads these directly; HEIC and others go through an ImageIO hop first.
  private static let inputs: Set<UTType> = [.png, .jpeg, .tiff]

  public static func declaredCapabilities(backendID: String = "webp") -> [Capability] {
    [
      Capability(
        backendID: backendID, input: inputs, output: .webP, quality: 85, speed: 60,
        isNative: false,
        params: [ParamSpec(key: "quality", label: "Quality", kind: .range(1, 100), defaultValue: "80")])
    ]
  }

  public func capabilities() -> [Capability] { Self.declaredCapabilities(backendID: id) }

  public func run(_ job: JobSpec, progress: Progress) async throws -> [URL] {
    let name = job.input.deletingPathExtension().lastPathComponent
    let target = job.outputDirectory.appendingPathComponent("\(name).webp")
    let quality = job.params["quality"].flatMap(Int.init).map { min(max($0, 1), 100) } ?? 80

    // cwebp ignores EXIF orientation and ICC profiles and copies no metadata, so feed it
    // pixels that are already upright and in sRGB.
    guard let oriented = OrientedImage.load(job.input),
      let normalized = OrientedImage.normalizedSRGB(oriented)
    else { throw BackendError.unreadable(job.input) }
    let staged = job.outputDirectory.appendingPathComponent("\(name)-normalized.png")
    guard OrientedImage.writePNG(normalized, to: staged) else {
      throw BackendError.encodeFailed(staged.lastPathComponent)
    }
    defer { try? FileManager.default.removeItem(at: staged) }

    try await ProcessRunner.run(
      executable, arguments: ["-quiet", "-q", String(quality), staged.path, "-o", target.path])
    return [target]
  }
}
