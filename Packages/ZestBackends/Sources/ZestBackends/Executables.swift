import Foundation

/// Finds command-line engines. A GUI app's PATH is minimal, so well-known install
/// locations come first, then every PATH entry.
enum Executables {
  static let knownDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]

  static func candidates(for name: String, extraDirectories: [String] = []) -> [String] {
    let onPath = (ProcessInfo.processInfo.environment["PATH"] ?? "")
      .split(separator: ":").map(String.init)
    var seen = Set<String>()
    return (knownDirectories + extraDirectories + onPath)
      .filter { !$0.isEmpty && seen.insert($0).inserted }
      .map { ($0 as NSString).appendingPathComponent(name) }
  }

  static func find(_ name: String, extraPaths: [String] = []) -> URL? {
    for path in extraPaths + candidates(for: name)
    where FileManager.default.isExecutableFile(atPath: path) {
      return URL(fileURLWithPath: path)
    }
    return nil
  }
}
