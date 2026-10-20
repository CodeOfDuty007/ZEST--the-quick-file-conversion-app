import Foundation
import UniformTypeIdentifiers

/// One button on the wheel: a branch that opens a deeper ring, or a leaf that runs.
public struct WheelNode: Sendable, Equatable, Identifiable {
  public enum Action: Sendable, Equatable {
    case branch
    case convert(UTType)
    case tool(String)
  }

  public let id: String
  public let title: String
  public let symbol: String
  public let action: Action
  public let children: [WheelNode]
  /// Set when the node is shown dimmed; the text explains why.
  public let disabledReason: String?
  /// True when choosing the node opens an editor window; the wheel marks it with a glyph.
  public let opensEditor: Bool

  public init(
    id: String, title: String, symbol: String, action: Action, children: [WheelNode] = [],
    disabledReason: String? = nil, opensEditor: Bool = false
  ) {
    self.id = id
    self.title = title
    self.symbol = symbol
    self.action = action
    self.children = children
    self.disabledReason = disabledReason
    self.opensEditor = opensEditor
  }

  public var isBranch: Bool { action == .branch }
  public var isEnabled: Bool { disabledReason == nil }
  /// Only enabled leaves accept a drop; branches are entered by holding.
  public var isDroppable: Bool { !isBranch && isEnabled }
}

/// Builds the tree for a selection: four roots, each pruned to what applies.
public enum WheelTree {
  public static let root = "root"

  /// Common formats first, so the ring is stable between drags.
  private static let popularity: [UTType] = [
    .jpeg, .png, .heic, .pdf, Formats.markdown, .html, .mpeg4Movie, .mp3, .mpeg4Audio, .wav,
    .tiff, .gif, .webP, .quickTimeMovie, .bmp,
  ]

  /// - Parameter dimmed: per-tool reasons for this particular selection that types alone
  ///   cannot express (for example a multi-page TIFF the editors cannot open).
  public static func build(
    router: Router, inputs: [UTType], dimmed: [String: String] = [:]
  ) -> WheelNode {
    var roots: [WheelNode] = []

    for kind in ToolSpec.Root.allCases {
      let leaves: [WheelNode]
      if kind == .convert {
        leaves = convertLeaves(router: router, inputs: inputs)
      } else {
        leaves = toolLeaves(router: router, inputs: inputs, root: kind, dimmed: dimmed)
      }
      guard !leaves.isEmpty else { continue }
      roots.append(
        WheelNode(
          id: "root.\(kind.rawValue)", title: kind.title, symbol: kind.symbol, action: .branch,
          children: ring(leaves, idPrefix: "root.\(kind.rawValue)")))
    }
    return WheelNode(id: root, title: "Zest", symbol: "chart.pie.fill", action: .branch, children: roots)
  }

  private static func convertLeaves(router: Router, inputs: [UTType]) -> [WheelNode] {
    let outputs = router.resolve(inputs: inputs).available.map(\.output).sorted { a, b in
      let ia = popularity.firstIndex(of: a) ?? Int.max
      let ib = popularity.firstIndex(of: b) ?? Int.max
      if ia != ib { return ia < ib }
      return Formats.fileExtension(for: a) < Formats.fileExtension(for: b)
    }
    return outputs.map { type in
      WheelNode(
        id: "convert:\(type.identifier)", title: Formats.fileExtension(for: type).uppercased(),
        symbol: symbol(for: type), action: .convert(type))
    }
  }

  private static func toolLeaves(
    router: Router, inputs: [UTType], root: ToolSpec.Root, dimmed: [String: String]
  ) -> [WheelNode] {
    router.evaluateTools(inputs: inputs).compactMap { entry in
      guard entry.tool.root == root else { return nil }
      switch entry.visibility {
      case .hidden:
        return nil
      case .enabled:
        return leaf(for: entry.tool, disabledReason: dimmed[entry.tool.id])
      case .disabled(let reason):
        return leaf(for: entry.tool, disabledReason: reason.description)
      }
    }
  }

  private static func leaf(for tool: ToolSpec, disabledReason: String?) -> WheelNode {
    WheelNode(
      id: "tool:\(tool.id)", title: tool.title, symbol: tool.symbol, action: .tool(tool.id),
      disabledReason: disabledReason, opensEditor: tool.status != .ready)
  }

  /// A ring holds at most `WheelGeometry.maxWedges`. Overflow moves into a "More" branch,
  /// which is itself just another branch (and can overflow in turn).
  static func ring(_ nodes: [WheelNode], idPrefix: String) -> [WheelNode] {
    let limit = WheelGeometry.maxWedges
    guard nodes.count > limit else { return nodes }
    let shown = Array(nodes.prefix(limit - 1))
    let rest = Array(nodes.dropFirst(limit - 1))
    let more = WheelNode(
      id: "\(idPrefix).more", title: "More", symbol: "ellipsis", action: .branch,
      children: ring(rest, idPrefix: "\(idPrefix).more"))
    return shown + [more]
  }

  public static func symbol(for type: UTType) -> String {
    if type.conforms(to: .image) { return "photo" }
    if type.conforms(to: .audio) { return "waveform" }
    if type.conforms(to: .movie) { return "film" }
    if type.conforms(to: .pdf) { return "doc.richtext" }
    if type == .html { return "chevron.left.forwardslash.chevron.right" }
    if type == Formats.markdown { return "text.alignleft" }
    if type.conforms(to: .archive) { return "archivebox" }
    return "doc"
  }
}
