import Foundation
import os

/// Phase 0 diagnostics: every event the spike cares about, timestamped, shown in the
/// menu and appended to ~/Library/Logs/Zest/spike.log so a run can be read back.
@MainActor
final class SpikeLog: ObservableObject {
  static let shared = SpikeLog()

  @Published private(set) var lines: [String] = []

  let fileURL: URL
  private let logger = Logger(subsystem: "org.zest.Zest", category: "spike")
  private let formatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
  }()

  private init() {
    let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Logs/Zest", isDirectory: true)
    try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    fileURL = logs.appendingPathComponent("spike.log")
  }

  func log(_ message: String) {
    let line = "\(formatter.string(from: Date())) \(message)"
    lines.append(line)
    if lines.count > 200 { lines.removeFirst(lines.count - 200) }
    logger.info("\(message, privacy: .public)")

    guard let data = (line + "\n").data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: fileURL) {
      handle.seekToEndOfFile()
      handle.write(data)
      try? handle.close()
    } else {
      try? data.write(to: fileURL)
    }
  }
}
