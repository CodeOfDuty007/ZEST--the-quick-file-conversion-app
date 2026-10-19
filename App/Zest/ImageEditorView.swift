import AppKit
import SwiftUI
import ZestBackends
import ZestCore

struct ImageEditorView: View {
  @ObservedObject var model: ImageEditorModel
  let onClose: () -> Void

  var body: some View {
    HStack(spacing: 0) {
      ToolStrip(model: model)
      Divider()
      VStack(spacing: 0) {
        Canvas(model: model)
        Divider()
        OptionsBar(model: model, onClose: onClose)
      }
    }
    .tint(Theme.accent)
    .frame(minWidth: 760, minHeight: 520)
  }
}

// MARK: Tool strip

private struct ToolStrip: View {
  @ObservedObject var model: ImageEditorModel

  var body: some View {
    VStack(spacing: 6) {
      ForEach(ImageEditorModel.Tool.allCases) { tool in
        Button {
          model.tool = tool
        } label: {
          VStack(spacing: 3) {
            Image(systemName: tool.symbol).font(.system(size: 18, weight: .medium))
            Text(tool.title).font(.system(size: 10, weight: .medium))
          }
          .frame(width: 66, height: 54)
          .foregroundStyle(model.tool == tool ? Color.white : Color.primary)
          .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .fill(model.tool == tool ? Theme.accent : Color.clear))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tool.title)
        .accessibilityAddTraits(model.tool == tool ? [.isButton, .isSelected] : .isButton)
      }
      Spacer()
    }
    .padding(8)
    .frame(width: 84)
    .background(.regularMaterial)
  }
}

// MARK: Canvas

private struct Canvas: View {
  @ObservedObject var model: ImageEditorModel
  @State private var dragStart: CGPoint?
  @State private var dragNow: CGPoint?

  /// Where the image sits inside the view: aspect-fit, centred.
  private struct Layout {
    let scale: CGFloat
    let origin: CGPoint

    init(view: CGSize, image: CGSize) {
      scale = min(view.width / image.width, view.height / image.height)
      origin = CGPoint(
        x: (view.width - image.width * scale) / 2, y: (view.height - image.height * scale) / 2)
    }

    func toImage(_ p: CGPoint, in size: CGSize) -> CGPoint {
      CGPoint(
        x: min(max((p.x - origin.x) / scale, 0), size.width),
        y: min(max((p.y - origin.y) / scale, 0), size.height))
    }

    func toView(_ p: CGPoint) -> CGPoint {
      CGPoint(x: origin.x + p.x * scale, y: origin.y + p.y * scale)
    }

    func toView(_ r: CGRect) -> CGRect {
      CGRect(x: origin.x + r.minX * scale, y: origin.y + r.minY * scale, width: r.width * scale, height: r.height * scale)
    }
  }

  var body: some View {
    let shown = model.displayImage
    let size = CGSize(width: shown.width, height: shown.height)

    GeometryReader { proxy in
      let layout = Layout(view: proxy.size, image: size)
      ZStack(alignment: .topLeading) {
        Rectangle().fill(Color(nsColor: .underPageBackgroundColor))
        Image(decorative: shown, scale: 1)
          .resizable()
          .interpolation(.medium)
          .frame(width: size.width * layout.scale, height: size.height * layout.scale)
          .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
          .shadow(color: .black.opacity(0.25), radius: 10, y: 3)

        overlay(layout: layout, size: size)

        // The drag gesture lives on its own layer, below the text field, so clicking or
        // typing in the field never counts as a drag on the image.
        Color.clear
          .contentShape(Rectangle())
          .gesture(
            DragGesture(minimumDistance: 0)
              .onChanged { value in
                if dragStart == nil { dragStart = value.startLocation }
                dragNow = value.location
              }
              .onEnded { value in
                finish(start: value.startLocation, end: value.location, layout: layout, size: size)
                dragStart = nil
                dragNow = nil
              }
          )

        if let anchor = model.textAnchor, model.tool == .annotate {
          let at = layout.toView(anchor)
          TextField("Text", text: $model.textDraft)
            .textFieldStyle(.roundedBorder)
            .frame(width: 180)
            .position(x: at.x + 90, y: at.y + 14)
            .onSubmit { model.placeText() }
        }
      }
    }
    .accessibilityLabel("Image canvas")
  }

  /// Live feedback while dragging, plus the pending crop box.
  @ViewBuilder
  private func overlay(layout: Layout, size: CGSize) -> some View {
    if let crop = model.pendingCrop, model.tool == .crop {
      let rect = layout.toView(crop)
      Rectangle().stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
        .background(Theme.accent.opacity(0.12))
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .allowsHitTesting(false)
    }
    if let start = dragStart, let now = dragNow {
      let rect = CGRect(
        x: min(start.x, now.x), y: min(start.y, now.y), width: abs(now.x - start.x),
        height: abs(now.y - start.y))
      switch model.tool {
      case .crop:
        Rectangle().stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
          .frame(width: rect.width, height: rect.height)
          .position(x: rect.midX, y: rect.midY)
          .allowsHitTesting(false)
      case .redact:
        Rectangle().fill(Color.black.opacity(0.85))
          .frame(width: rect.width, height: rect.height)
          .position(x: rect.midX, y: rect.midY)
          .allowsHitTesting(false)
      case .annotate where model.mark == .rectangle:
        Rectangle().stroke(model.color.swiftUI, lineWidth: 3)
          .frame(width: rect.width, height: rect.height)
          .position(x: rect.midX, y: rect.midY)
          .allowsHitTesting(false)
      case .annotate where model.mark == .arrow:
        Path { path in
          path.move(to: start)
          path.addLine(to: now)
        }
        .stroke(model.color.swiftUI, style: StrokeStyle(lineWidth: 3, lineCap: .round))
        .allowsHitTesting(false)
      default:
        EmptyView()
      }
    }
  }

  private func finish(start: CGPoint, end: CGPoint, layout: Layout, size: CGSize) {
    let a = layout.toImage(start, in: size)
    let b = layout.toImage(end, in: size)
    let rect = CGRect(
      x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))

    switch model.tool {
    case .crop:
      if rect.width >= 4, rect.height >= 4 { model.pendingCrop = rect }
    case .redact:
      model.redact(rect)
    case .annotate:
      if model.mark == .text {
        // Clicking elsewhere finishes the text being typed instead of throwing it away.
        if model.textAnchor != nil { model.placeText() }
        model.textAnchor = a
        model.textDraft = ""
      } else {
        model.addMark(from: a, to: b)
      }
    case .background:
      break
    }
  }
}

// MARK: Options bar

private struct OptionsBar: View {
  @ObservedObject var model: ImageEditorModel
  let onClose: () -> Void

  var body: some View {
    HStack(spacing: 14) {
      options
      Spacer(minLength: 8)
      if let message = model.message {
        Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      Button("Undo") { model.undo() }
        .keyboardShortcut("z")
        .disabled(!model.canUndo)
      Button("Cancel", role: .cancel, action: onClose)
        .keyboardShortcut(.cancelAction)
      Button("Save as copy") {
        if let url = model.save() {
          NSWorkspace.shared.activateFileViewerSelecting([url])
          onClose()
        }
      }
      .keyboardShortcut("s")
      .buttonStyle(.borderedProminent)
    }
    .padding(12)
    .background(.regularMaterial)
  }

  @ViewBuilder
  private var options: some View {
    switch model.tool {
    case .crop:
      Text(model.pendingCrop == nil ? "Drag to choose the area to keep" : "Press Apply to crop")
        .font(.callout).foregroundStyle(.secondary)
      if model.pendingCrop != nil {
        Button("Apply crop") { model.applyCrop() }
          .keyboardShortcut(.defaultAction)
        Button("Clear") { model.cancelPending() }
      }

    case .annotate:
      Picker("Mark", selection: $model.mark) {
        ForEach(ImageEditorModel.Mark.allCases) { mark in
          Label(mark.title, systemImage: mark.symbol).tag(mark)
        }
      }
      .pickerStyle(.segmented)
      .frame(width: 220)
      .labelsHidden()
      Swatches(model: model)
      HStack(spacing: 4) {
        Image(systemName: "lineweight").foregroundStyle(.secondary)
        Slider(value: $model.strokeScale, in: 1...5).frame(width: 90)
      }

    case .redact:
      Label("Drag over anything to remove. It is burned in and cannot be undone after saving.", systemImage: "exclamationmark.shield")
        .font(.callout).foregroundStyle(.secondary).lineLimit(1)

    case .background:
      HStack(spacing: 8) {
        ForEach(Array(BackdropStyle.presets.enumerated()), id: \.offset) { index, preset in
          Button {
            model.backgroundIndex = index
          } label: {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .fill(
                LinearGradient(
                  colors: [preset.style.top.swiftUI, preset.style.bottom.swiftUI],
                  startPoint: .top, endPoint: .bottom)
              )
              .frame(width: 34, height: 26)
              .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                  .stroke(model.backgroundIndex == index ? Color.primary : Color.clear, lineWidth: 2))
          }
          .buttonStyle(.plain)
          .help(preset.name)
          .accessibilityLabel(preset.name)
        }
      }
      Button("Apply background") { model.applyBackground() }
    }
  }
}

private struct Swatches: View {
  @ObservedObject var model: ImageEditorModel

  var body: some View {
    HStack(spacing: 6) {
      ForEach(Array(ImageEditorModel.swatches.enumerated()), id: \.offset) { _, swatch in
        Button {
          model.color = swatch
        } label: {
          Circle().fill(swatch.swiftUI).frame(width: 20, height: 20)
            .overlay(Circle().stroke(Color.primary.opacity(model.color == swatch ? 1 : 0.2), lineWidth: model.color == swatch ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Colour")
      }
    }
  }
}

extension EditColor {
  var swiftUI: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
}
