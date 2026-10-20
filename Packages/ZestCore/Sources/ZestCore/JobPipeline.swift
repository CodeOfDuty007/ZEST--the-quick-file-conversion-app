import Foundation

/// Runs a route in a private temp folder, validates the result, then moves it
/// beside the original. The source file is never opened for writing (N-03, N-04).
public struct JobPipeline: Sendable {
  private let backends: [String: any Backend]
  private let tempRoot: URL

  public struct ToolReport: Sendable {
    public struct Skipped: Sendable, Equatable {
      public let input: URL
      public let reason: String
    }
    public let published: [URL]
    public let skipped: [Skipped]
  }

  public init(
    backends: [any Backend],
    tempRoot: URL = FileManager.default.temporaryDirectory
  ) {
    self.backends = Dictionary(uniqueKeysWithValues: backends.map { ($0.id, $0) })
    self.tempRoot = tempRoot
  }

  /// Runs a route that produces one file and returns it.
  /// - Returns: the URL of the published output.
  public func run(
    input: URL,
    route: Route,
    params: [String: String] = [:],
    destinationDirectory: URL? = nil,
    progress: Progress = Progress()
  ) async throws -> URL {
    let outputs = try await runAll(
      input: input, route: route, params: params, destinationDirectory: destinationDirectory,
      progress: progress)
    guard let first = outputs.first else { throw ZestError.noOutputProduced }
    return first
  }

  /// Runs a route and returns every published file. A step may produce several (a PDF
  /// becomes one image per page); the next step then runs on each of them.
  public func runAll(
    input: URL,
    route: Route,
    params: [String: String] = [:],
    destinationDirectory: URL? = nil,
    progress: Progress = Progress()
  ) async throws -> [URL] {
    let fm = FileManager.default
    guard fm.fileExists(atPath: input.path) else { throw ZestError.sourceMissing(input) }

    let work = tempRoot.appendingPathComponent("zest-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: work) }

    var current = [input]
    for (index, step) in route.steps.enumerated() {
      try Task.checkCancellation()
      guard let backend = backends[step.backendID] else {
        throw ZestError.backendMissing(step.backendID)
      }
      var produced: [URL] = []
      for (fileIndex, file) in current.enumerated() {
        try Task.checkCancellation()
        let stepDir = work.appendingPathComponent("step\(index)-\(fileIndex)", isDirectory: true)
        try fm.createDirectory(at: stepDir, withIntermediateDirectories: true)
        let spec = JobSpec(input: file, capability: step, outputDirectory: stepDir, params: params)
        let outputs = try await backend.run(spec, progress: progress)
        guard !outputs.isEmpty else { throw ZestError.noOutputProduced }
        for output in outputs { try Self.validate(output) }
        produced += outputs
      }
      current = produced
    }

    try Task.checkCancellation()
    return try publish(current, source: input, route: route, directory: destinationDirectory)
  }

  /// One input's outcome in a batch.
  public struct BatchItem: Sendable {
    public let input: URL
    public let result: Result<[URL], any Error>
  }

  /// Converts several files at once, up to `maxConcurrent` at a time. Results come back in
  /// the order of `inputs`; one file failing never stops the others.
  public func runBatch(
    inputs: [URL],
    routes: [Route],
    params: [String: String] = [:],
    destinationDirectory: URL? = nil,
    maxConcurrent: Int = 4
  ) async -> [BatchItem] {
    precondition(inputs.count == routes.count, "one route per input")
    let limit = max(1, maxConcurrent)
    var results = [BatchItem?](repeating: nil, count: inputs.count)

    await withTaskGroup(of: (Int, BatchItem).self) { group in
      var next = 0
      func launch() {
        guard next < inputs.count else { return }
        let index = next
        next += 1
        group.addTask {
          let input = inputs[index]
          do {
            let outputs = try await self.runAll(
              input: input, route: routes[index], params: params,
              destinationDirectory: destinationDirectory)
            return (index, BatchItem(input: input, result: .success(outputs)))
          } catch {
            return (index, BatchItem(input: input, result: .failure(error)))
          }
        }
      }
      for _ in 0..<min(limit, inputs.count) { launch() }
      while let (index, item) = await group.next() {
        results[index] = item
        launch()
      }
    }
    return results.enumerated().map { index, item in
      item ?? BatchItem(input: inputs[index], result: .failure(CancellationError()))
    }
  }

  private static func validate(_ url: URL) throws {
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    guard size > 0 else { throw ZestError.emptyOutput(url) }
  }

  /// Publishes every file beside the source, or none: a failure part-way removes whatever
  /// was already placed. One file is named after the source; several keep their own names.
  private func publish(_ files: [URL], source: URL, route: Route, directory: URL?) throws -> [URL] {
    let fm = FileManager.default
    let dir = directory ?? source.deletingLastPathComponent()
    let ext = Formats.fileExtension(for: route.output)
    let sourceBase = source.deletingPathExtension().lastPathComponent

    // Stage next to the destination first. If the temp folder is on another volume the
    // move is a copy, and a crash mid-copy must not leave a half-written file under its
    // real name. The final rename inside one folder is atomic.
    var staged: [(file: URL, base: String)] = []
    var finals: [URL] = []
    var committed = false
    defer {
      if !committed {
        for entry in staged { try? fm.removeItem(at: entry.file) }
        for url in finals { try? fm.removeItem(at: url) }
      }
    }
    for file in files {
      let part = dir.appendingPathComponent(".zest-\(UUID().uuidString).part")
      try fm.moveItem(at: file, to: part)
      let base = files.count == 1 ? sourceBase : file.deletingPathExtension().lastPathComponent
      staged.append((part, base))
    }
    // A cross-volume stage can take long enough for the job to be cancelled meanwhile.
    try Task.checkCancellation()

    // The rename fails if the target appeared since we looked, so retry with the next number.
    for entry in staged {
      var placed = false
      for _ in 0..<100 {
        let target = OutputNaming.uniqueURL(directory: dir, baseName: entry.base, ext: ext)
        do {
          try fm.moveItem(at: entry.file, to: target)
          finals.append(target)
          placed = true
          break
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
          continue
        }
      }
      if !placed { throw ZestError.couldNotPublish(source) }
      staged.removeAll { $0.file == entry.file }
    }
    committed = true
    return finals
  }

  // MARK: Tools

  /// Runs a tool over one or more files. Outputs are published together: if any step
  /// fails, nothing is left behind.
  public func runTool(
    _ tool: ToolSpec,
    inputs: [URL],
    destinationDirectory: URL? = nil,
    progress: Progress = Progress()
  ) async throws -> ToolReport {
    let fm = FileManager.default
    guard !inputs.isEmpty else { throw ZestError.noOutputProduced }
    for input in inputs where !fm.fileExists(atPath: input.path) {
      throw ZestError.sourceMissing(input)
    }
    guard let backend = backends[tool.backendID] as? any ToolBackend else {
      throw ZestError.backendMissing(tool.backendID)
    }

    let work = tempRoot.appendingPathComponent("zest-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: work) }

    try Task.checkCancellation()
    let result = try await backend.runTool(
      ToolJob(inputs: inputs, tool: tool, outputDirectory: work), progress: progress)
    guard !result.outputs.isEmpty || !result.skipped.isEmpty else {
      throw ZestError.noOutputProduced
    }
    for output in result.outputs { try Self.validate(output.url) }
    try Task.checkCancellation()

    let published = try publishAll(
      result.outputs, tool: tool, inputs: inputs, destination: destinationDirectory)
    let skipped = result.skipped.compactMap { skip -> ToolReport.Skipped? in
      inputs.indices.contains(skip.source)
        ? ToolReport.Skipped(input: inputs[skip.source], reason: skip.reason) : nil
    }
    return ToolReport(published: published, skipped: skipped)
  }

  private func publishAll(
    _ outputs: [ToolOutput], tool: ToolSpec, inputs: [URL], destination: URL?
  ) throws -> [URL] {
    let fm = FileManager.default
    struct Plan {
      let staged: URL
      let directory: URL
      let base: String
      let ext: String
    }

    // Stage everything next to its destination first; a cross-volume copy must not appear
    // under a real name until it is complete.
    var plans: [Plan] = []
    var stagedFiles: [URL] = []
    var finals: [URL] = []
    var committed = false
    defer {
      if !committed {
        for url in stagedFiles + finals { try? fm.removeItem(at: url) }
      }
    }

    for output in outputs {
      let sourceIndex = output.source ?? 0
      let source = inputs[min(sourceIndex, inputs.count - 1)]
      let directory = destination ?? source.deletingLastPathComponent()
      let base: String
      switch tool.shape {
      case .transform, .group:
        base = source.deletingPathExtension().lastPathComponent + tool.nameSuffix
      case .fanOut:
        base = output.url.deletingPathExtension().lastPathComponent
      }
      let staged = directory.appendingPathComponent(".zest-\(UUID().uuidString).part")
      try fm.moveItem(at: output.url, to: staged)
      stagedFiles.append(staged)
      plans.append(
        Plan(staged: staged, directory: directory, base: base, ext: output.url.pathExtension))
    }

    try Task.checkCancellation()

    for plan in plans {
      var placed = false
      for _ in 0..<100 {
        let target = OutputNaming.uniqueURL(
          directory: plan.directory, baseName: plan.base, ext: plan.ext)
        do {
          try fm.moveItem(at: plan.staged, to: target)
          finals.append(target)
          stagedFiles.removeAll { $0 == plan.staged }
          placed = true
          break
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
          continue
        }
      }
      if !placed { throw ZestError.couldNotPublish(plan.directory) }
    }
    committed = true
    return finals
  }
}
