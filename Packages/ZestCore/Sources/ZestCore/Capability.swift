import Foundation
import UniformTypeIdentifiers

public enum Operation: String, Sendable, Codable, CaseIterable {
  case convert, compress, resize, rotate, trim, stripMetadata
}

/// Describes one option a capability accepts; drives the options sub-wheel.
public struct ParamSpec: Sendable, Hashable {
  public enum Kind: Sendable, Hashable {
    case choice([String])
    case range(Int, Int)
    case toggle
  }

  public let key: String
  public let label: String
  public let kind: Kind
  public let defaultValue: String

  public init(key: String, label: String, kind: Kind, defaultValue: String) {
    self.key = key
    self.label = label
    self.kind = kind
    self.defaultValue = defaultValue
  }
}

/// One edge of the format graph: a backend can turn `input` into `output`.
public struct Capability: Sendable, Hashable {
  public let backendID: String
  public let input: Set<UTType>
  public let output: UTType
  public let operation: Operation
  /// 0–100, used to rank competing paths.
  public let quality: Int
  /// 0–100, tie-breaker after quality and nativeness.
  public let speed: Int
  /// True for Apple frameworks, false for bundled or user-installed engines.
  public let isNative: Bool
  /// True when the output is safe to use as an intermediate in a two-hop route.
  public let isLosslessOutput: Bool
  public let params: [ParamSpec]

  public init(
    backendID: String,
    input: Set<UTType>,
    output: UTType,
    operation: Operation = .convert,
    quality: Int,
    speed: Int = 50,
    isNative: Bool,
    isLosslessOutput: Bool = false,
    params: [ParamSpec] = []
  ) {
    self.backendID = backendID
    self.input = input
    self.output = output
    self.operation = operation
    self.quality = quality
    self.speed = speed
    self.isNative = isNative
    self.isLosslessOutput = isLosslessOutput
    self.params = params
  }
}
