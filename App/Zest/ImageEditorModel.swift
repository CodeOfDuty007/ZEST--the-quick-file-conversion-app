import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import ZestBackends
import ZestCore

/// State and actions for the image editor window. Pixel work lives in `ImageEditing`;
/// this class only tracks the current image, an undo stack and what the user is doing.
@MainActor
final class ImageEditorModel: ObservableObject {
  enum Tool: String, CaseIterable, Identifiable {
    case crop, annotate, redact, background
    var id: String { rawValue }

    var title: String {
      switch self {
      case .crop: return "Crop"
      case .annotate: return "Annotate"
      case .redact: return "Redact"
      case .background: return "Background"
      }
    }

    var symbol: String {
      switch self {
      case .crop: return "crop"
      case .annotate: return "pencil.tip.crop.circle"
      case .redact: return "rectangle.dashed"
      case .background: return "rectangle.on.rectangle"
      }
    }

    init?(toolID: String) {
      switch toolID {
      case "crop.image": self = .crop
      case "annotate.image": self = .annotate
      case "redact.image": self = .redact
      case "background.image": self = .background
      default: return nil
      }
    }
  }

  enum Mark: String, CaseIterable, Identifiable {
    case rectangle, arrow, text
    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var symbol: String {
      switch self {
      case .rectangle: return "rectangle"
      case .arrow: return "arrow.up.right"
      case .text: return "textformat"
      }
    }
  }

  static let swatches: [EditColor] = [.red, .orange, .blue, .green, .white, .black]

  let source: URL
  let sourceType: UTType
  @Published private(set) var image: CGImage
  @Published var tool: Tool {
    didSet {
      if tool != oldValue {
        // Text that is typed but not submitted is work in progress, not something to drop.
        if textAnchor != nil { placeText() }
        // A drawn crop box is applied, as it is on Save, rather than silently dropped.
        // commit() already refreshes the preview; only refresh here when nothing was committed,
        // so a large background is not rasterised twice.
        if pendingCrop == nil || !applyCrop() { refreshPreview() }
      }
    }
  }
  @Published var mark: Mark = .rectangle
  @Published var color: EditColor = .red
  /// 1…5; scaled by image size so marks look the same on a phone photo and a screenshot.
  @Published var strokeScale: Double = 2
  @Published var pendingCrop: CGRect?
  @Published var textAnchor: CGPoint?
  @Published var textDraft = ""
  @Published var backgroundIndex = 0 {
    didSet { refreshPreview() }
  }
  /// The background applied to the working image, rebuilt only when something it depends on
  /// changes. Dragging on the canvas redraws constantly and must not re-rasterise it.
  @Published private(set) var preview: CGImage?
  @Published private(set) var message: String?
  @Published private(set) var edited = false

  private var history: [CGImage] = []
  /// Undo keeps whole images, so it is capped by count and by total bytes.
  private static let maxUndoSteps = 20
  private static let maxUndoBytes = 400_000_000

  /// Only single-frame images can be edited; saving would silently drop other frames.
  static func canEdit(_ url: URL) -> Bool {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
    return CGImageSourceGetCount(source) == 1
  }

  init?(source: URL, tool: Tool) {
    guard Self.canEdit(source), let image = OrientedImage.load(source) else { return nil }
    self.source = source
    self.sourceType = ContentSniffer.type(ofFileAt: source) ?? .png
    self.image = image
    self.tool = tool
    refreshPreview()
  }

  var canUndo: Bool { !history.isEmpty }
  var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }
  var backgroundStyle: BackdropStyle { BackdropStyle.presets[backgroundIndex].style }

  /// What the canvas shows: the working image, or a live preview of the background.
  var displayImage: CGImage { preview ?? image }

  private func refreshPreview() {
    preview = tool == .background ? ImageEditing.addBackground(image, style: backgroundStyle) : nil
  }

  private func trimHistory() {
    func bytes(_ image: CGImage) -> Int { image.width * image.height * 4 }
    while history.count > Self.maxUndoSteps
      || history.reduce(0, { $0 + bytes($1) }) > Self.maxUndoBytes, history.count > 1
    {
      history.removeFirst()
    }
  }

  private var lineWidth: CGFloat {
    CGFloat(max(image.width, image.height)) * 0.0022 * CGFloat(strokeScale)
  }

  // MARK: Edits

  @discardableResult
  private func commit(_ new: CGImage?, _ note: String) -> Bool {
    guard let new else {
      message = "That edit could not be applied."
      return false
    }
    history.append(image)
    trimHistory()
    image = new
    edited = true
    message = note
    refreshPreview()
    return true
  }

  func undo() {
    guard let previous = history.popLast() else { return }
    image = previous
    pendingCrop = nil
    message = "Undone"
    edited = !history.isEmpty
    refreshPreview()
  }

  /// Returns whether the crop was applied; the preview is refreshed by `commit` only on success.
  @discardableResult
  func applyCrop() -> Bool {
    guard let rect = pendingCrop else { return false }
    pendingCrop = nil
    return commit(ImageEditing.crop(image, to: rect), "Cropped")
  }

  func cancelPending() {
    pendingCrop = nil
    textAnchor = nil
    textDraft = ""
  }

  func redact(_ rect: CGRect) {
    guard rect.width >= 2, rect.height >= 2 else { return }
    commit(ImageEditing.redact(image, rects: [rect]), "Redacted. The pixels are permanently removed.")
  }

  func addMark(from start: CGPoint, to end: CGPoint) {
    let item: ImageAnnotation
    switch mark {
    case .rectangle:
      let rect = CGRect(
        x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x),
        height: abs(end.y - start.y))
      guard rect.width >= 2, rect.height >= 2 else { return }
      item = ImageAnnotation(.rectangle(rect), color: color, lineWidth: lineWidth)
    case .arrow:
      guard hypot(end.x - start.x, end.y - start.y) >= 6 else { return }
      item = ImageAnnotation(.arrow(from: start, to: end), color: color, lineWidth: lineWidth)
    case .text:
      return
    }
    commit(ImageEditing.annotate(image, items: [item]), "Added \(mark.title.lowercased())")
  }

  func placeText() {
    guard let anchor = textAnchor else { return }
    let text = textDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    textAnchor = nil
    textDraft = ""
    guard !text.isEmpty else { return }
    let size = CGFloat(max(image.width, image.height)) * 0.03 * CGFloat(strokeScale) / 2
    let item = ImageAnnotation(.text(text, at: anchor, fontSize: size), color: color)
    commit(ImageEditing.annotate(image, items: [item]), "Added text")
  }

  func applyBackground() {
    guard let result = ImageEditing.addBackground(image, style: backgroundStyle) else { return }
    commit(result, "Background added")
    tool = .annotate
  }

  // MARK: Save

  /// Saves beside the original as `name edited.ext`. The original is never touched, and the
  /// file appears under its real name only once it is completely written.
  func save() -> URL? {
    // A crop box or text that is drawn but not yet confirmed is part of what the user sees,
    // so saving must include it rather than silently drop it.
    if pendingCrop != nil { applyCrop() }
    if textAnchor != nil { placeText() }
    // A background still being previewed counts as part of the edit.
    let final = displayImage
    let type = ImageEditing.saveType(for: sourceType)
    let directory = source.deletingLastPathComponent()
    let staged = directory.appendingPathComponent(".zest-\(UUID().uuidString).part")
    let fm = FileManager.default
    do {
      try ImageEditing.write(final, as: type, to: staged)
      for _ in 0..<100 {
        let target = OutputNaming.uniqueURL(
          directory: directory,
          baseName: source.deletingPathExtension().lastPathComponent + " edited",
          ext: Formats.fileExtension(for: type))
        do {
          try fm.moveItem(at: staged, to: target)
          return target
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
          continue
        }
      }
      throw ZestError.couldNotPublish(source)
    } catch {
      try? fm.removeItem(at: staged)
      message = "Could not save: \(error.localizedDescription)"
      return nil
    }
  }
}
