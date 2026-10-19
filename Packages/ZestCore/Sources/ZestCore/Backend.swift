import Foundation

/// A conversion engine. Each backend declares what it can do and runs one step.
public protocol Backend: Sendable {
  var id: String { get }
  /// Static capabilities plus anything detected at launch.
  func capabilities() -> [Capability]
  /// Runs one step. Output files must be written inside `job.outputDirectory`.
  func run(_ job: JobSpec, progress: Progress) async throws -> [URL]
}

/// One resolved step handed to a backend.
public struct JobSpec: Sendable {
  public let input: URL
  public let capability: Capability
  public let outputDirectory: URL
  public let params: [String: String]

  public init(
    input: URL,
    capability: Capability,
    outputDirectory: URL,
    params: [String: String] = [:]
  ) {
    self.input = input
    self.capability = capability
    self.outputDirectory = outputDirectory
    self.params = params
  }
}

public enum ZestError: Error, LocalizedError {
  case sourceMissing(URL)
  case backendMissing(String)
  case noOutputProduced
  case emptyOutput(URL)
  case couldNotPublish(URL)

  public var errorDescription: String? {
    switch self {
    case .sourceMissing(let url): return "The file \(url.lastPathComponent) no longer exists."
    case .backendMissing(let id): return "The \(id) engine is not available."
    case .noOutputProduced: return "The conversion finished without producing a file."
    case .emptyOutput(let url): return "The converted file \(url.lastPathComponent) is empty."
    case .couldNotPublish(let url): return "Could not save the result beside \(url.lastPathComponent)."
    }
  }
}
