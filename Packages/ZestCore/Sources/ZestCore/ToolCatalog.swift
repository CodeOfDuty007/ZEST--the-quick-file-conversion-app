import Foundation
import UniformTypeIdentifiers

/// Tools that are planned or need an editor window. They show on the wheel as dimmed
/// leaves so the full tree is visible; backends supply the ones that actually run.
public enum PlannedTools {
  private static let images: Set<UTType> = [.image]
  /// Still formats only. The editors load one frame and save a flat image, so an animated
  /// GIF or WebP must not be offered.
  private static let stills: Set<UTType> = [.jpeg, .png, .heic, .tiff, .bmp]
  private static let video: Set<UTType> = [.movie, .mpeg4Movie, .quickTimeMovie]
  private static let audio: Set<UTType> = [.audio]

  public static let all: [ToolSpec] = [
    // Image editors open a window in the app.
    live("crop.image", "Crop", "crop", accepts: stills),
    live("annotate.image", "Annotate", "pencil.tip.crop.circle", accepts: stills),
    live("redact.image", "Redact", "rectangle.dashed", accepts: stills),
    live("background.image", "Background", "rectangle.on.rectangle", accepts: stills),
    // Video and audio editors are still to come.
    editor("crop.video", "Crop", "crop", accepts: video),
    editor("trim.video", "Trim", "scissors", accepts: video),
    editor("trim.audio", "Trim", "scissors", accepts: audio),
    editor("redact.video", "Redact", "rectangle.dashed", accepts: video),
    editor("bleep", "Bleep", "speaker.slash", accepts: audio),
    soon("split-video", "Split", "square.split.2x1", root: .edit, accepts: video),
    soon("join-video", "Join", "plus.rectangle.on.rectangle", root: .edit, accepts: video),
    soon("compress-pdf", "PDF", "doc.zipper", root: .compress, accepts: [.pdf]),
  ]

  /// An editor that opens in the app today.
  private static func live(
    _ id: String, _ title: String, _ symbol: String, accepts: Set<UTType>
  ) -> ToolSpec {
    ToolSpec(
      id: id, backendID: "editor", root: .edit, title: title, symbol: symbol, accepts: accepts,
      status: .opensEditor, maxInputs: 1)
  }

  private static func editor(
    _ id: String, _ title: String, _ symbol: String, accepts: Set<UTType>
  ) -> ToolSpec {
    ToolSpec(
      id: id, backendID: "editor", root: .edit, title: title, symbol: symbol, accepts: accepts,
      status: .needsEditor, maxInputs: 1)
  }

  private static func soon(
    _ id: String, _ title: String, _ symbol: String, root: ToolSpec.Root, accepts: Set<UTType>
  ) -> ToolSpec {
    ToolSpec(
      id: id, backendID: "zest", root: root, title: title, symbol: symbol, accepts: accepts,
      status: .comingSoon)
  }
}
