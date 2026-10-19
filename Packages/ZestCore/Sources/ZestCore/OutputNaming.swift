import Foundation

/// Finder-style collision naming: `name.ext`, `name 2.ext`, `name 3.ext` (F-06).
public enum OutputNaming {
  public static func uniqueURL(
    directory: URL,
    baseName: String,
    ext: String,
    exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
  ) -> URL {
    var candidate = directory.appendingPathComponent(baseName).appendingPathExtension(ext)
    var n = 2
    while exists(candidate) {
      candidate = directory.appendingPathComponent("\(baseName) \(n)").appendingPathExtension(ext)
      n += 1
    }
    return candidate
  }
}
