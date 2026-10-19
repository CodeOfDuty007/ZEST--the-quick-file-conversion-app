import Foundation
import UniformTypeIdentifiers
import ZestCore

/// Audio and video conversion through an FFmpeg binary. Until the static build
/// lands (Vendor/), this uses an FFmpeg already on disk.
public struct FFmpegBackend: ToolBackend {
  public let id = "ffmpeg"
  let executable: URL

  public init(executable: URL) { self.executable = executable }

  public static var searchPaths: [String] { Executables.candidates(for: "ffmpeg") }

  /// Returns nil when no FFmpeg is found.
  public static func detect(extraPaths: [String] = []) -> FFmpegBackend? {
    Executables.find("ffmpeg", extraPaths: extraPaths).map { FFmpegBackend(executable: $0) }
  }

  private static let videoInputs: Set<UTType> = [
    .mpeg4Movie, .quickTimeMovie, .avi, Formats.mkv, Formats.webm, Formats.wmv,
  ]
  private static let videoOutputs: [UTType] = [
    .mpeg4Movie, .quickTimeMovie, Formats.mkv, Formats.webm, .gif,
  ]
  private static let audioInputs: Set<UTType> = [
    .mp3, .wav, .aiff, .mpeg4Audio, Formats.flac, Formats.ogg, Formats.opus, Formats.wma,
  ]
  /// WMA is decode-only, so it is an input above but never an output.
  private static let audioOutputs: [UTType] = [
    .mp3, .wav, .aiff, .mpeg4Audio, Formats.flac, Formats.ogg, Formats.opus,
  ]
  private static let losslessAudio: Set<UTType> = [.wav, .aiff, Formats.flac]

  /// Everything FFmpeg could do, whether or not it is installed. The catalog uses
  /// this to explain why a format is missing.
  public static func declaredCapabilities(backendID: String = "ffmpeg") -> [Capability] {
    var caps: [Capability] = []
    for output in videoOutputs {
      caps.append(
        Capability(
          backendID: backendID, input: videoInputs, output: output, quality: 70, speed: 50,
          isNative: false))
    }
    // Audio to video: the sound over a plain still frame.
    for output in [UTType.mpeg4Movie, .quickTimeMovie] {
      caps.append(
        Capability(
          backendID: backendID, input: audioInputs, output: output, quality: 60, speed: 50,
          isNative: false))
    }
    for output in audioOutputs {
      caps.append(
        Capability(
          backendID: backendID, input: audioInputs, output: output, quality: 70, speed: 60,
          isNative: false, isLosslessOutput: losslessAudio.contains(output)))
    }
    return caps
  }

  public func capabilities() -> [Capability] { Self.declaredCapabilities(backendID: id) }

  // MARK: Tools

  private static let videoCompressible: Set<UTType> = [.mpeg4Movie, .quickTimeMovie]
  private static let audioCompressible: Set<UTType> = [.mp3, .mpeg4Audio]
  private static let avStrippable: Set<UTType> = [
    .mpeg4Movie, .quickTimeMovie, .mp3, .mpeg4Audio, Formats.mkv, Formats.webm,
  ]
  /// Constant-rate-factor for each target size: lower is bigger and sharper.
  private static let crf = [25: 35, 50: 30, 75: 26]
  private static let audioKbps = [25: 64, 50: 96, 75: 160]

  /// What each tool needs from FFmpeg, whether or not it is installed.
  public static func declaredTools(backendID: String = "ffmpeg") -> [ToolSpec] {
    var tools: [ToolSpec] = []
    for percent in [25, 50, 75] {
      tools.append(
        ToolSpec(
          id: "compress.video.\(percent)", backendID: backendID, root: .compress,
          title: "\(percent)%", symbol: "arrow.down.right.and.arrow.up.left",
          accepts: videoCompressible, params: ["percent": "\(percent)"],
          nameSuffix: " compressed"))
      tools.append(
        ToolSpec(
          id: "compress.audio.\(percent)", backendID: backendID, root: .compress,
          title: "\(percent)%", symbol: "arrow.down.right.and.arrow.up.left",
          accepts: audioCompressible, params: ["percent": "\(percent)"],
          nameSuffix: " compressed"))
    }
    tools.append(
      ToolSpec(
        id: "strip.av", backendID: backendID, root: .files, title: "Metadata", symbol: "eye.slash",
        accepts: avStrippable, nameSuffix: " stripped"))
    return tools
  }

  public func tools() -> [ToolSpec] { Self.declaredTools(backendID: id) }

  public func runTool(_ job: ToolJob, progress: Progress) async throws -> ToolResult {
    progress.totalUnitCount = Int64(job.inputs.count)
    var outputs: [ToolOutput] = []
    var skipped: [ToolSkip] = []

    for (index, input) in job.inputs.enumerated() {
      try Task.checkCancellation()
      defer { progress.completedUnitCount += 1 }
      let percent = Int(job.tool.params["percent"] ?? "50") ?? 50
      // Name the temp file for what is inside it, not for what the user called it.
      let kind = ContentSniffer.type(ofFileAt: input)
      let ext = kind.map(Formats.fileExtension(for:)) ?? input.pathExtension
      let stem = input.deletingPathExtension().lastPathComponent
      let out = job.outputDirectory.appendingPathComponent("\(index)-\(stem).\(ext)")
      let before = Self.fileSize(input)
      let targetBytes = before * percent / 100

      var arguments = ["-nostdin", "-y", "-loglevel", "error", "-i", input.path]
      switch job.tool.id {
      case let id where id.hasPrefix("compress.video."):
        arguments += try await videoArguments(for: input, targetBytes: targetBytes, percent: percent)
      case let id where id.hasPrefix("compress.audio."):
        let kbps = try await audioKbps(for: input, targetBytes: targetBytes, percent: percent)
        let isMP3 = kind == .mp3
        arguments += ["-vn", "-c:a", isMP3 ? "libmp3lame" : "aac", "-b:a", "\(kbps)k"]
      case "strip.av":
        // Stream copy: nothing is re-encoded, only tags and chapters are dropped.
        arguments += ["-map", "0", "-map_metadata", "-1", "-map_chapters", "-1", "-c", "copy"]
      default:
        throw ZestError.backendMissing(job.tool.id)
      }
      arguments.append(out.path)
      try await ProcessRunner.run(executable, arguments: arguments)

      if job.tool.id.hasPrefix("compress.") {
        let after = Self.fileSize(out)
        // Rate control is approximate, so allow a little over; anything further means the
        // target was out of reach and a success report would be false.
        if after >= before || Double(after) > Double(targetBytes) * Self.sizeTolerance {
          try? FileManager.default.removeItem(at: out)
          let reason = after >= before ? "Already small" : "Can't reach \(percent)% without ruining it"
          skipped.append(ToolSkip(source: index, reason: reason))
          continue
        }
      }
      outputs.append(ToolOutput(url: out, source: index))
    }
    return ToolResult(outputs: outputs, skipped: skipped)
  }

  /// Rate control lands within this factor of the target.
  static let sizeTolerance = 1.15

  private static func fileSize(_ url: URL) -> Int {
    (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
  }

  private var ffprobe: URL? {
    let url = executable.deletingLastPathComponent().appendingPathComponent("ffprobe")
    return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
  }

  /// Duration in seconds, or nil if it cannot be read.
  private func duration(of url: URL) async -> Double? {
    guard let ffprobe else { return nil }
    let text = try? await ProcessRunner.output(
      ffprobe,
      arguments: ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", url.path])
    return text.flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
  }

  /// Bitrate that lands the file at the target size, clamped to what codecs can do.
  private func audioKbps(for url: URL, targetBytes: Int, percent: Int) async throws -> Int {
    guard let seconds = await duration(of: url), seconds > 0 else {
      return Self.audioKbps[percent] ?? 96  // preset fallback; the size check still guards it
    }
    return min(max(Int(Double(targetBytes) * 8 / seconds / 1000), 16), 320)
  }

  private func videoArguments(for url: URL, targetBytes: Int, percent: Int) async throws -> [String] {
    let common = ["-c:v", "libx264", "-preset", "fast", "-pix_fmt", "yuv420p", "-movflags", "+faststart"]
    guard let seconds = await duration(of: url), seconds > 0 else {
      return common + ["-crf", "\(Self.crf[percent] ?? 30)", "-c:a", "aac", "-b:a", "128k"]
    }
    let audioKbps = 96
    let totalKbps = Double(targetBytes) * 8 / seconds / 1000
    let videoKbps = max(Int(totalKbps) - audioKbps, 50)
    return common + [
      "-b:v", "\(videoKbps)k", "-maxrate", "\(Int(Double(videoKbps) * 1.2))k",
      "-bufsize", "\(videoKbps * 2)k", "-c:a", "aac", "-b:a", "\(audioKbps)k",
    ]
  }

  public func run(_ job: JobSpec, progress: Progress) async throws -> [URL] {
    let ext = Formats.fileExtension(for: job.capability.output)
    let name = job.input.deletingPathExtension().lastPathComponent
    let target = job.outputDirectory.appendingPathComponent("\(name).\(ext)")

    var arguments = ["-nostdin", "-y", "-loglevel", "error"]
    let inputIsAudio = ContentSniffer.type(ofFileAt: job.input)?.conforms(to: .audio) ?? false
    let outputIsVideo = job.capability.output.conforms(to: .movie)
    if inputIsAudio && outputIsVideo {
      // A dark 720p still at 2 fps; the video ends when the audio does.
      arguments += [
        "-f", "lavfi", "-i", "color=c=black:s=1280x720:r=2", "-i", job.input.path,
        "-shortest", "-c:v", "libx264", "-tune", "stillimage", "-pix_fmt", "yuv420p",
        "-c:a", "aac", "-b:a", "192k",
      ]
    } else {
      arguments += ["-i", job.input.path]
    }
    if job.capability.output == .gif {
      arguments += ["-vf", "fps=15,scale=480:-1:flags=lanczos"]
    }
    arguments.append(target.path)

    try await ProcessRunner.run(executable, arguments: arguments)
    return [target]
  }
}

/// Runs a child process and throws with its stderr tail on failure. Cancelling the
/// task terminates the process.
enum ProcessRunner {
  private final class Capture: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
  }

  /// Runs a process and returns what it printed to stdout.
  static func output(_ executable: URL, arguments: [String]) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      let process = Process()
      process.executableURL = executable
      process.arguments = arguments
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = FileHandle.nullDevice
      process.terminationHandler = { finished in
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if finished.terminationStatus == 0 {
          continuation.resume(returning: String(decoding: data, as: UTF8.self))
        } else {
          continuation.resume(
            throwing: BackendError.processFailed(status: finished.terminationStatus, stderr: ""))
        }
      }
      do { try process.run() } catch { continuation.resume(throwing: error) }
    }
  }

  static func run(_ executable: URL, arguments: [String]) async throws {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    let errPipe = Pipe()
    process.standardError = errPipe
    process.standardOutput = FileHandle.nullDevice
    let capture = Capture()
    errPipe.fileHandleForReading.readabilityHandler = { handle in
      capture.append(handle.availableData)
    }

    let gate = CancelGate()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        if gate.isCancelled {
          continuation.resume(throwing: CancellationError())
          return
        }
        process.terminationHandler = { finished in
          errPipe.fileHandleForReading.readabilityHandler = nil
          capture.append(errPipe.fileHandleForReading.readDataToEndOfFile())
          if finished.terminationStatus == 0 {
            continuation.resume()
          } else if finished.terminationReason == .uncaughtSignal {
            continuation.resume(throwing: CancellationError())
          } else {
            continuation.resume(
              throwing: BackendError.processFailed(
                status: finished.terminationStatus, stderr: capture.text))
          }
        }
        do {
          try process.run()
          // Cancellation may have landed between the check above and the launch.
          if gate.isCancelled { process.terminate() }
        } catch {
          continuation.resume(throwing: error)
        }
      }
    } onCancel: {
      gate.cancel()
      if process.isRunning { process.terminate() }
    }
  }

  /// Remembers a cancel request so it still applies if it arrives before launch.
  private final class CancelGate: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
  }
}
