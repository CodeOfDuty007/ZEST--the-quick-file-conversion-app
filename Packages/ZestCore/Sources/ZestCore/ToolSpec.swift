import Foundation
import UniformTypeIdentifiers

/// A leaf operation that is not "convert to a fixed format": compress, strip metadata,
/// merge, split and so on. Conversions stay `Capability` edges; tools are described here.
public struct ToolSpec: Sendable, Hashable, Identifiable {
  /// The four top-level branches of the wheel.
  public enum Root: String, Sendable, CaseIterable {
    case convert, compress, edit, files

    public var title: String {
      switch self {
      case .convert: return "Convert"
      case .compress: return "Compress"
      case .edit: return "Edit"
      case .files: return "Files"
      }
    }

    public var symbol: String {
      switch self {
      case .convert: return "arrow.triangle.2.circlepath"
      case .compress: return "arrow.down.right.and.arrow.up.left"
      case .edit: return "slider.horizontal.3"
      case .files: return "doc.on.doc"
      }
    }
  }

  /// How inputs map to outputs.
  public enum Shape: Sendable, Hashable {
    /// Each input becomes one output of the same kind (compress, strip metadata).
    case transform
    /// At least `minimum` inputs become one output (merge, collage, join).
    case group(minimum: Int)
    /// Each input becomes several outputs (split a PDF into pages).
    case fanOut
  }

  /// Whether the tool can run today.
  public enum Status: Sendable, Hashable {
    case ready
    /// Opens an editor window when chosen (crop, annotate…). Runs in the app, not the pipeline.
    case opensEditor
    /// Needs an editor window that is not built yet.
    case needsEditor
    case comingSoon
  }

  public let id: String
  public let backendID: String
  public let root: Root
  public let title: String
  public let symbol: String
  public let shape: Shape
  public let accepts: Set<UTType>
  public let params: [String: String]
  /// Appended to the source name: `photo` + ` compressed` = `photo compressed.jpg`.
  public let nameSuffix: String
  /// Output type for group tools, whose output is not any single input's type.
  public let groupOutput: UTType?
  public let status: Status
  /// Most files the tool takes at once (editors work on one).
  public let maxInputs: Int?

  public init(
    id: String,
    backendID: String,
    root: Root,
    title: String,
    symbol: String,
    shape: Shape = .transform,
    accepts: Set<UTType>,
    params: [String: String] = [:],
    nameSuffix: String = "",
    groupOutput: UTType? = nil,
    status: Status = .ready,
    maxInputs: Int? = nil
  ) {
    self.id = id
    self.backendID = backendID
    self.root = root
    self.title = title
    self.symbol = symbol
    self.shape = shape
    self.accepts = accepts
    self.params = params
    self.nameSuffix = nameSuffix
    self.groupOutput = groupOutput
    self.status = status
    self.maxInputs = maxInputs
  }
}

public enum ToolReason: Sendable, Equatable, CustomStringConvertible {
  case wrongType(UTType)
  case needsAtLeast(Int)
  case needsSingleFile
  case needsEditor
  case comingSoon
  case backendUnavailable(backend: String, reason: String)

  public var description: String {
    switch self {
    case .wrongType(let type):
      return "Does not apply to \(Formats.fileExtension(for: type).uppercased()) files."
    case .needsAtLeast(let count):
      return "Select at least \(count) files."
    case .needsSingleFile:
      return "Select a single file."
    case .needsEditor:
      return "Opens an editor window, which is coming soon."
    case .comingSoon:
      return "Coming soon."
    case .backendUnavailable(let backend, let reason):
      return "Needs \(backend): \(reason)"
    }
  }
}

/// What the wheel does with a tool for the current selection.
public enum ToolVisibility: Sendable, Equatable {
  case enabled
  /// Shown dimmed with the reason, so the user knows it exists.
  case disabled(ToolReason)
  /// Not applicable to this selection; left off the wheel but kept for the debug panel (F-28).
  case hidden(ToolReason)
}

/// One of the outputs a tool run produced.
public struct ToolOutput: Sendable {
  public let url: URL
  /// Index of the input this came from, for naming; nil for group tools.
  public let source: Int?

  public init(url: URL, source: Int?) {
    self.url = url
    self.source = source
  }
}

public struct ToolSkip: Sendable, Equatable {
  public let source: Int
  public let reason: String

  public init(source: Int, reason: String) {
    self.source = source
    self.reason = reason
  }
}

/// What a backend returns from a tool run.
public struct ToolResult: Sendable {
  public let outputs: [ToolOutput]
  /// Inputs deliberately left alone (already small, nothing to strip…), with why.
  public let skipped: [ToolSkip]

  public init(outputs: [ToolOutput], skipped: [ToolSkip] = []) {
    self.outputs = outputs
    self.skipped = skipped
  }
}

public struct ToolJob: Sendable {
  public let inputs: [URL]
  public let tool: ToolSpec
  public let outputDirectory: URL

  public init(inputs: [URL], tool: ToolSpec, outputDirectory: URL) {
    self.inputs = inputs
    self.tool = tool
    self.outputDirectory = outputDirectory
  }
}

/// A backend that also runs tools.
public protocol ToolBackend: Backend {
  func tools() -> [ToolSpec]
  func runTool(_ job: ToolJob, progress: Progress) async throws -> ToolResult
}

/// A tool whose engine is missing right now.
public struct UnavailableTool: Sendable {
  public let tool: ToolSpec
  public let reason: String

  public init(tool: ToolSpec, reason: String) {
    self.tool = tool
    self.reason = reason
  }
}
