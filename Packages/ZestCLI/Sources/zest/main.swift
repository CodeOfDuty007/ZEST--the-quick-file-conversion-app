import Foundation
import UniformTypeIdentifiers
import ZestBackends
import ZestCore

let usage = """
  zest — convert files with the same engine as the Zest app

  USAGE
    zest list-outputs <file>...      Formats these files can be converted to
    zest why <file> <format>         Why a format is, or is not, offered
    zest convert <file>... --to <format> [--quality 1-100] [--out <folder>]
    zest tools <file>...             Every tool for these files, with why any are hidden
    zest run <tool> <file>...        Run a tool (see `zest tools`), e.g. compress.image.50
    zest compress <file>... [--to 25|50|75]   Compress images, video or audio
    zest strip <file>...             Remove metadata (EXIF, GPS, tags, PDF info)
    zest merge <file>...             Merge PDFs, or combine images into one PDF
    zest split <pdf>...              One PDF per page
    zest backends                    Engines found on this Mac
    zest help
  """

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("zest: \(message)\n".utf8))
  exit(1)
}

func label(_ type: UTType) -> String { Formats.fileExtension(for: type) }

func inputType(_ path: String) -> (URL, UTType) {
  let url = URL(fileURLWithPath: path)
  guard FileManager.default.fileExists(atPath: url.path) else { fail("no such file: \(path)") }
  guard let type = ContentSniffer.type(ofFileAt: url) else {
    fail("can't tell what kind of file this is: \(path)")
  }
  return (url, type)
}

/// Splits `--flag value` pairs from positional arguments.
func parse(_ args: [String]) -> (positional: [String], flags: [String: String]) {
  var positional: [String] = []
  var flags: [String: String] = [:]
  var index = 0
  while index < args.count {
    let arg = args[index]
    if arg.hasPrefix("--") {
      guard index + 1 < args.count else { fail("\(arg) needs a value") }
      flags[String(arg.dropFirst(2))] = args[index + 1]
      index += 2
    } else {
      positional.append(arg)
      index += 1
    }
  }
  return (positional, flags)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
  print(usage)
  exit(0)
}
let rest = Array(arguments.dropFirst())
let catalog = Catalog()

switch command {
case "help", "--help", "-h":
  print(usage)

case "backends":
  for backend in catalog.backends {
    let count = backend.capabilities().count
    print("\(backend.id)\t\(count) conversions")
  }
  if !catalog.backends.contains(where: { $0.id == "ffmpeg" }) {
    print("ffmpeg\tnot found (audio and video formats are unavailable)")
  }

case "list-outputs":
  let files = parse(rest).positional
  guard !files.isEmpty else { fail("usage: zest list-outputs <file>...") }
  let types = files.map { inputType($0).1 }
  let result = catalog.router.resolve(inputs: types)
  if result.available.isEmpty {
    print("No conversions available for this selection.")
  }
  for option in result.available {
    let hops = option.routes.map(\.hops).max() ?? 1
    print("\(label(option.output))\(hops > 1 ? "  (via intermediate)" : "")")
  }

case "why":
  let positional = parse(rest).positional
  guard positional.count == 2 else { fail("usage: zest why <file> <format>") }
  let (_, type) = inputType(positional[0])
  guard let target = Formats.type(named: positional[1]) else {
    fail("unknown format: \(positional[1])")
  }
  let result = catalog.router.resolve(inputs: [type])
  if let option = result.available.first(where: { $0.output == target }) {
    let steps = option.routes[0].steps.map(\.backendID).joined(separator: " → ")
    print("Offered: \(label(type)) → \(label(target)) via \(steps)")
  } else if let rejection = result.rejected.first(where: { $0.output == target }) {
    print("Hidden: \(rejection.reason)")
  } else {
    print("Hidden: no engine knows how to write \(label(target)).")
  }

case "convert":
  let (positional, flags) = parse(rest)
  guard !positional.isEmpty, let formatName = flags["to"] else {
    fail("usage: zest convert <file>... --to <format>")
  }
  guard let target = Formats.type(named: formatName) else { fail("unknown format: \(formatName)") }
  let destination = flags["out"].map { URL(fileURLWithPath: $0, isDirectory: true) }
  var params: [String: String] = [:]
  if let quality = flags["quality"] {
    guard let value = Int(quality), (1...100).contains(value) else {
      fail("--quality must be between 1 and 100")
    }
    params["quality"] = quality
  }

  var failures = 0
  for path in positional {
    let (url, type) = inputType(path)
    // Same rules as list-outputs and why, so convert never runs a hidden route.
    let resolution = catalog.router.resolve(inputs: [type])
    guard let route = resolution.available.first(where: { $0.output == target })?.routes.first else {
      let why = resolution.rejected
        .first { $0.output == target }?.reason.description ?? "no engine can do this"
      FileHandle.standardError.write(Data("zest: \(url.lastPathComponent): \(why)\n".utf8))
      failures += 1
      continue
    }
    // Never accept an option the chosen route would silently ignore.
    if params["quality"] != nil,
      !route.steps.contains(where: { $0.params.contains { $0.key == "quality" } })
    {
      FileHandle.standardError.write(
        Data(
          "zest: \(url.lastPathComponent): --quality does not apply to \(label(type)) → \(label(target))\n"
            .utf8))
      failures += 1
      continue
    }
    do {
      let outs = try await catalog.pipeline.runAll(
        input: url, route: route, params: params, destinationDirectory: destination)
      for out in outs { print(out.path) }
    } catch {
      FileHandle.standardError.write(
        Data("zest: \(url.lastPathComponent): \(error.localizedDescription)\n".utf8))
      failures += 1
    }
  }
  exit(failures == 0 ? 0 : 1)

case "tools":
  let files = parse(rest).positional
  guard !files.isEmpty else { fail("usage: zest tools <file>...") }
  let types = files.map { inputType($0).1 }
  for entry in catalog.router.evaluateTools(inputs: types) {
    switch entry.visibility {
    case .enabled where entry.tool.status == .opensEditor:
      print("editor    \(entry.tool.id)\t\(entry.tool.root.title) › \(entry.tool.title) (opens in the Zest app)")
    case .enabled: print("ready     \(entry.tool.id)\t\(entry.tool.root.title) › \(entry.tool.title)")
    case .disabled(let reason): print("dimmed    \(entry.tool.id)\t\(reason)")
    case .hidden(let reason): print("hidden    \(entry.tool.id)\t\(reason)")
    }
  }

case "run", "compress", "strip", "merge", "split":
  var (positional, flags) = parse(rest)
  var toolID: String
  if command == "run" {
    guard !positional.isEmpty else { fail("usage: zest run <tool> <file>...") }
    toolID = positional.removeFirst()
  } else {
    // Friendly aliases pick the tool that matches the first file's type.
    guard let first = positional.first else { fail("usage: zest \(command) <file>...") }
    let kind = inputType(first).1
    let percent = flags["to"] ?? "50"
    let family = kind.conforms(to: .image) ? "image" : kind.conforms(to: .movie) ? "video" : kind.conforms(to: .audio) ? "audio" : "pdf"
    switch command {
    case "compress": toolID = "compress.\(family).\(percent)"
    case "strip": toolID = family == "pdf" ? "strip.pdf" : family == "image" ? "strip.image" : "strip.av"
    case "merge": toolID = family == "pdf" ? "pdf.merge" : "images.to.pdf"
    default: toolID = "pdf.split"
    }
  }
  guard !positional.isEmpty else { fail("no files given") }
  let types = positional.map { inputType($0).1 }
  // Resolve through the evaluated catalogue so a tool whose engine is missing still
  // reports the real reason instead of "unknown tool".
  guard let tool = catalog.router.evaluateTools(inputs: types).first(where: { $0.tool.id == toolID })?.tool
  else {
    fail("unknown tool: \(toolID). Try 'zest tools <file>'.")
  }
  if tool.status == .opensEditor {
    fail("\(tool.id) opens an editor window in the Zest app, so it cannot run from the command line.")
  }
  switch catalog.router.visibility(of: tool, inputs: types) {
  case .enabled: break
  case .disabled(let reason), .hidden(let reason): fail("\(tool.id): \(reason)")
  }
  do {
    let report = try await catalog.pipeline.runTool(
      tool, inputs: positional.map { URL(fileURLWithPath: $0) },
      destinationDirectory: flags["out"].map { URL(fileURLWithPath: $0, isDirectory: true) })
    for url in report.published { print(url.path) }
    for skip in report.skipped {
      FileHandle.standardError.write(Data("zest: \(skip.input.lastPathComponent): \(skip.reason)\n".utf8))
    }
    exit(report.published.isEmpty && !report.skipped.isEmpty ? 2 : 0)
  } catch {
    fail(error.localizedDescription)
  }

default:
  fail("unknown command '\(command)'. Try 'zest help'.")
}
