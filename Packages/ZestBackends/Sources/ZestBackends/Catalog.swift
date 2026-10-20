import Foundation
import ZestCore

/// Detects the engines available on this Mac and builds the router and pipeline.
public struct Catalog: Sendable {
  public let backends: [any Backend]
  public let router: Router

  public init(ffmpegSearchPaths: [String] = []) {
    var backends: [any Backend] = [
      ImageIOBackend(), ImageToPDFBackend(), ImageToolsBackend(), PDFToolsBackend(),
      PDFRenderBackend(), DocumentBackend(), DocumentExportBackend(), RedactBackend(),
    ]
    var unavailable: [UnavailableCapability] = []
    var unavailableTools: [UnavailableTool] = []

    if let ffmpeg = FFmpegBackend.detect(extraPaths: ffmpegSearchPaths) {
      backends.append(ffmpeg)
    } else {
      unavailable += FFmpegBackend.declaredCapabilities().map {
        UnavailableCapability(capability: $0, reason: "FFmpeg was not found on this Mac.")
      }
      unavailableTools += FFmpegBackend.declaredTools().map {
        UnavailableTool(tool: $0, reason: "FFmpeg was not found on this Mac.")
      }
    }

    if let webp = WebPBackend.detect() {
      backends.append(webp)
    } else {
      unavailable += WebPBackend.declaredCapabilities().map {
        UnavailableCapability(capability: $0, reason: "cwebp (libwebp) was not found on this Mac.")
      }
    }

    self.backends = backends
    // Runnable tools first, then planned ones (editors, coming soon) so the tree shows them dimmed.
    let runnable = backends.compactMap { $0 as? any ToolBackend }.flatMap { $0.tools() }
    self.router = Router(
      capabilities: backends.flatMap { $0.capabilities() }, unavailable: unavailable,
      tools: runnable + PlannedTools.all, unavailableTools: unavailableTools)
  }

  public var pipeline: JobPipeline { JobPipeline(backends: backends) }
}
