import Foundation
import UniformTypeIdentifiers

/// Format names, file extensions and the few types the system does not declare.
public enum Formats {
  public static let mkv = type(ext: "mkv")
  public static let webm = type(ext: "webm")
  public static let flac = type(ext: "flac")
  public static let ogg = type(ext: "ogg")
  public static let opus = type(ext: "opus")
  public static let wma = type(ext: "wma")
  public static let wmv = type(ext: "wmv")
  public static let avif = type(ext: "avif")

  private static func type(ext: String) -> UTType {
    UTType(filenameExtension: ext) ?? .data
  }

  /// Extension Zest writes for a type. Finder users expect `jpg`, not `jpeg`.
  private static let extensionOverrides: [UTType: String] = [
    .jpeg: "jpg",
    .tiff: "tiff",
    .mpeg4Movie: "mp4",
    .quickTimeMovie: "mov",
    .mpeg4Audio: "m4a",
    .mp3: "mp3",
    .wav: "wav",
    .aiff: "aiff",
  ]

  public static func fileExtension(for type: UTType) -> String {
    if let override = extensionOverrides[type] { return override }
    return type.preferredFilenameExtension
      ?? type.tags[.filenameExtension]?.first
      ?? "bin"
  }

  /// Resolves a user-typed format such as `jpg`, `JPEG`, `.png` or `mp4`.
  public static func type(named name: String) -> UTType? {
    let cleaned = name.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
    guard !cleaned.isEmpty else { return nil }
    let alias = ["jpg": "jpeg", "tif": "tiff", "mov": "mov", "m4a": "m4a"]
    let ext = alias[cleaned] ?? cleaned
    return UTType(filenameExtension: ext)
  }
}
