import Foundation
import UniformTypeIdentifiers
import ZestCore

/// Turns almost any file into Markdown or HTML. Each input kind has a reader that produces
/// the shared block model; the two writers render it, so every input reaches both outputs.
public struct DocumentBackend: Backend {
  public let id = "document"

  public init() {}

  private static let word: [UTType] = [
    "org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc",
    "org.oasis-open.opendocument.text",
  ].compactMap { UTType($0) }

  /// Conformance based, so vendor subtypes (a `.docx`, a `.mkv`) are covered too.
  static let inputs: Set<UTType> =
    Set([.pdf, .image, .text, .rtf, .rtfd, .flatRTFD, .html, .audio, .movie] as [UTType]).union(word)

  public func capabilities() -> [Capability] {
    [Formats.markdown, .html].map { output in
      Capability(
        backendID: id, input: Self.inputs, output: output, quality: 80, speed: 60, isNative: true)
    }
  }

  enum Kind { case pdf, rich, text, image, media }

  static func kind(of type: UTType) -> Kind? {
    if type.conforms(to: .pdf) { return .pdf }
    if type.conforms(to: .html) || type.conforms(to: .rtf) || type.conforms(to: .rtfd)
      || type.conforms(to: .flatRTFD) || word.contains(where: { type.conforms(to: $0) })
    {
      return .rich
    }
    if type.conforms(to: .text) { return .text }
    if type.conforms(to: .image) { return .image }
    if type.conforms(to: .audio) || type.conforms(to: .movie) { return .media }
    return nil
  }

  public func run(_ job: JobSpec, progress: Progress) async throws -> [URL] {
    let output = job.capability.output
    let asHTML = output == .html
    let input = job.input
    guard let type = ContentSniffer.type(ofFileAt: input), let kind = Self.kind(of: type) else {
      throw BackendError.unreadable(input)
    }

    let document: Document
    switch kind {
    case .pdf: document = try await PDFReader.read(url: input)
    case .rich: document = try await RichReader.read(url: input, type: type)
    case .text: document = try TextReader.read(url: input, type: type)
    case .image: document = try ImageReader.read(url: input, embed: asHTML)
    case .media: document = try await MediaReader.read(url: input, type: type)
    }
    try Task.checkCancellation()

    let text = asHTML ? HTMLWriter.render(document) : MarkdownWriter.render(document)
    let name = input.deletingPathExtension().lastPathComponent
    let target = job.outputDirectory.appendingPathComponent(
      "\(name).\(Formats.fileExtension(for: output))")
    do { try Data(text.utf8).write(to: target) } catch {
      throw BackendError.encodeFailed(target.lastPathComponent)
    }
    return [target]
  }
}
