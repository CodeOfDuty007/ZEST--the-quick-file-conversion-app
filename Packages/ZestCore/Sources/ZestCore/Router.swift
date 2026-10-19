import Foundation
import UniformTypeIdentifiers

/// A chain of one or two capabilities that turns an input type into an output type.
public struct Route: Sendable, Equatable {
  public let steps: [Capability]
  public var output: UTType { steps[steps.count - 1].output }
  public var hops: Int { steps.count }

  public init(steps: [Capability]) { self.steps = steps }
}

public enum RejectionReason: Sendable, Equatable, CustomStringConvertible {
  case sameFormat
  case noPath(input: UTType)
  case backendUnavailable(backend: String, reason: String)

  public var description: String {
    switch self {
    case .sameFormat:
      return "The file is already in this format."
    case .noPath(let input):
      return "No engine can convert \(Formats.fileExtension(for: input).uppercased()) to this format."
    case .backendUnavailable(let backend, let reason):
      return "Needs \(backend): \(reason)"
    }
  }
}

public struct Rejection: Sendable, Equatable {
  public let output: UTType
  public let reason: RejectionReason
}

/// A capability that exists but cannot run right now (engine missing).
public struct UnavailableCapability: Sendable {
  public let capability: Capability
  public let reason: String

  public init(capability: Capability, reason: String) {
    self.capability = capability
    self.reason = reason
  }
}

public struct Resolution: Sendable {
  public struct Option: Sendable {
    public let output: UTType
    /// One route per input, in the same order as the inputs passed to `resolve`.
    public let routes: [Route]
  }

  public let available: [Option]
  /// Every candidate that was hidden, with the rule that hid it (F-28, N-13).
  public let rejected: [Rejection]
}

/// Picks the best path for each wedge. Availability is computed here and nowhere else.
public struct Router: Sendable {
  public let capabilities: [Capability]
  public let unavailable: [UnavailableCapability]
  /// Runnable tools plus planned ones (editors, coming soon), which carry a non-ready status.
  public let tools: [ToolSpec]
  public let unavailableTools: [UnavailableTool]

  public init(
    capabilities: [Capability],
    unavailable: [UnavailableCapability] = [],
    tools: [ToolSpec] = [],
    unavailableTools: [UnavailableTool] = []
  ) {
    self.capabilities = capabilities
    self.unavailable = unavailable
    self.tools = tools
    self.unavailableTools = unavailableTools
  }

  /// The one function that decides whether a tool shows, dims or hides for a selection.
  public func visibility(of tool: ToolSpec, inputs: [UTType]) -> ToolVisibility {
    guard !inputs.isEmpty else { return .hidden(.needsAtLeast(1)) }
    if let offender = inputs.first(where: { type in
      !tool.accepts.contains { type.conforms(to: $0) }
    }) {
      return .hidden(.wrongType(offender))
    }
    if case .group(let minimum) = tool.shape, inputs.count < minimum {
      return .hidden(.needsAtLeast(minimum))
    }
    if let maximum = tool.maxInputs, inputs.count > maximum {
      return .hidden(.needsSingleFile)
    }
    switch tool.status {
    case .needsEditor: return .disabled(.needsEditor)
    case .comingSoon: return .disabled(.comingSoon)
    case .opensEditor: return .enabled
    case .ready: break
    }
    if let missing = unavailableTools.first(where: { $0.tool.id == tool.id }) {
      return .disabled(.backendUnavailable(backend: tool.backendID, reason: missing.reason))
    }
    return .enabled
  }

  /// Every known tool with its visibility for this selection, in catalogue order.
  public func evaluateTools(inputs: [UTType]) -> [(tool: ToolSpec, visibility: ToolVisibility)] {
    let known = tools + unavailableTools.map(\.tool).filter { u in !tools.contains { $0.id == u.id } }
    return known.map { ($0, visibility(of: $0, inputs: inputs)) }
  }

  /// Outputs reachable from every input (the intersection for mixed selections).
  public func resolve(inputs: [UTType], operation: Operation = .convert) -> Resolution {
    guard !inputs.isEmpty else { return Resolution(available: [], rejected: []) }

    var candidates = Set<UTType>()
    for cap in capabilities where cap.operation == operation { candidates.insert(cap.output) }
    for item in unavailable where item.capability.operation == operation {
      candidates.insert(item.capability.output)
    }

    var available: [Resolution.Option] = []
    var rejected: [Rejection] = []

    for output in candidates {
      var routes: [Route] = []
      var failure: RejectionReason?

      for input in inputs {
        // Conformance, not equality: a vendor subtype of the output is still that format.
        if operation == .convert && input.conforms(to: output) {
          failure = .sameFormat
          break
        }
        if let route = bestRoute(from: input, to: output, operation: operation) {
          routes.append(route)
        } else {
          failure = reasonForMissingRoute(from: input, to: output, operation: operation)
          break
        }
      }

      if let failure {
        rejected.append(Rejection(output: output, reason: failure))
      } else {
        available.append(Resolution.Option(output: output, routes: routes))
      }
    }

    available.sort { lhs, rhs in
      let l = Self.score(lhs.routes.min(by: Self.isWorse)!)
      let r = Self.score(rhs.routes.min(by: Self.isWorse)!)
      if l != r { return l.lexicographicallyPrecedes(r) == false }
      return lhs.output.identifier < rhs.output.identifier
    }
    rejected.sort { $0.output.identifier < $1.output.identifier }
    return Resolution(available: available, rejected: rejected)
  }

  /// Best route for one input, or nil. Direct edge first, then at most two hops
  /// through a lossless intermediate.
  public func bestRoute(from input: UTType, to output: UTType, operation: Operation = .convert) -> Route? {
    let direct = capabilities
      .filter { $0.operation == operation && $0.output == output && Self.accepts($0, input) }
      .map { Route(steps: [$0]) }
    if let best = direct.max(by: Self.isWorse) { return best }

    guard operation == .convert else { return nil }
    var twoHop: [Route] = []
    for first in capabilities
    where first.operation == .convert && first.isLosslessOutput
      && first.output != input && first.output != output && Self.accepts(first, input)
    {
      for second in capabilities
      where second.operation == .convert && second.output == output
        && Self.accepts(second, first.output)
      {
        twoHop.append(Route(steps: [first, second]))
      }
    }
    return twoHop.max(by: Self.isWorse)
  }

  private func reasonForMissingRoute(
    from input: UTType, to output: UTType, operation: Operation
  ) -> RejectionReason {
    if let hit = unavailable.first(where: {
      $0.capability.operation == operation && $0.capability.output == output
        && Self.accepts($0.capability, input)
    }) {
      return .backendUnavailable(backend: hit.capability.backendID, reason: hit.reason)
    }
    // The missing engine may be the second hop (HEIC → PNG → WebP needs cwebp).
    if operation == .convert {
      for first in capabilities
      where first.operation == .convert && first.isLosslessOutput && first.output != input
        && first.output != output && Self.accepts(first, input)
      {
        if let hit = unavailable.first(where: {
          $0.capability.operation == .convert && $0.capability.output == output
            && Self.accepts($0.capability, first.output)
        }) {
          return .backendUnavailable(backend: hit.capability.backendID, reason: hit.reason)
        }
      }
    }
    return .noPath(input: input)
  }

  static func accepts(_ capability: Capability, _ type: UTType) -> Bool {
    capability.input.contains { type.conforms(to: $0) }
  }

  /// (minimum quality, native steps, minimum speed); higher is better.
  private static func score(_ route: Route) -> [Int] {
    [
      route.steps.map(\.quality).min() ?? 0,
      route.steps.filter(\.isNative).count,
      route.steps.map(\.speed).min() ?? 0,
      -route.hops,
    ]
  }

  /// True when `a` ranks below `b`. Ties break on backend id so output is deterministic.
  private static func isWorse(_ a: Route, _ b: Route) -> Bool {
    let sa = score(a), sb = score(b)
    if sa != sb { return sa.lexicographicallyPrecedes(sb) }
    return a.steps.map(\.backendID).joined() > b.steps.map(\.backendID).joined()
  }
}
