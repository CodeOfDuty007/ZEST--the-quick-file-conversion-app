import SwiftUI
import ZestCore

enum Theme {
  /// The orange comes from the asset catalog's AccentColor so there is one source of truth.
  static let accent = Color.accentColor
}

struct WheelView: View {
  @ObservedObject var model: WheelModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  static let side: CGFloat = 320
  static let bubble: CGFloat = 66

  var body: some View {
    let geometry = model.geometry

    ZStack {
      // Fully transparent pixels may not count as "inside the window" during a drag, and
      // the pointer crosses the gaps between buttons. Without this the drag would exit
      // the window and close the wheel mid-gesture. Hit-testing itself is angular maths.
      Circle()
        .fill(Color.black.opacity(0.01))
        .frame(width: (geometry.outerRadius + geometry.closeMargin) * 2)
        .accessibilityHidden(true)

      // One glass container per level. The id gives each level a fresh view: the old ring is
      // removed outright (a removal transition can be left behind when the panel is hidden
      // mid-animation, which showed up as a ghost ring) and the new one grows in on appear.
      GlassBackdrop {
        ForEach(Array(model.nodes.enumerated()), id: \.element.id) { index, node in
          let angle = geometry.centreAngle(of: index)
          let radius = geometry.buttonRingRadius
          WheelButton(
            node: node, hovered: model.hovered == index,
            dwelling: model.dwellTarget == .child(index), dwell: model.dwell
          )
          .offset(x: radius * sin(angle), y: -radius * cos(angle))
        }
      }
      .modifier(RingAppear(reduceMotion: reduceMotion))
      .id(model.levelID)

      CentreBadge(model: model, radius: geometry.deadZoneRadius)
    }
    .frame(width: Self.side, height: Self.side)
    .scaleEffect(model.isOpen ? 1 : (reduceMotion ? 1 : 0.85))
    .opacity(model.isOpen ? 1 : 0)
    .animation(.easeOut(duration: 0.12), value: model.isOpen)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Zest wheel")
  }
}

/// Grows a ring in when its view first appears. Fresh state per level (see `.id`), so a
/// ring that was replaced never lingers and a reopened wheel always starts from rest.
private struct RingAppear: ViewModifier {
  let reduceMotion: Bool
  @State private var shown = false

  func body(content: Content) -> some View {
    content
      .opacity(shown ? 1 : 0)
      .scaleEffect(shown || reduceMotion ? 1 : 0.88)
      .onAppear { withAnimation(.easeOut(duration: 0.16)) { shown = true } }
  }
}

/// Groups the glass so Liquid Glass can blend neighbours on macOS 26; older systems get a plain stack.
private struct GlassBackdrop<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    if #available(macOS 26.0, *) {
      GlassEffectContainer(spacing: 12) { ZStack { content } }
    } else {
      ZStack { content }
    }
  }
}

/// One option on the ring: a round glass button with its icon and name inside. A branch
/// carries a chevron and fills a progress ring while you hold over it. The glass is applied
/// to the view that holds the label, so the text sits above it.
private struct WheelButton: View {
  let node: WheelNode
  let hovered: Bool
  let dwelling: Bool
  let dwell: TimeInterval

  var body: some View {
    VStack(spacing: 2) {
      Image(systemName: node.symbol)
        .font(.system(size: 18, weight: .medium))
      Text(node.title)
        .font(.system(size: 12, weight: .medium))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }
    .foregroundStyle(hovered && node.isEnabled ? Color.white : Color.primary)
    .frame(width: WheelView.bubble, height: WheelView.bubble)
    .modifier(
      GlassCircle(tint: hovered && node.isEnabled ? Theme.accent : nil, strong: hovered && node.isEnabled)
    )
    .overlay { DwellRing(active: dwelling, dwell: dwell, diameter: WheelView.bubble + 8) }
    .overlay(alignment: .bottomTrailing) {
      if node.opensEditor && node.isEnabled {
        Image(systemName: "macwindow")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Theme.accent)
          .padding(3)
          .background(.thinMaterial, in: Circle())
          .offset(x: 2, y: 2)
          .accessibilityHidden(true)
      }
    }
    .overlay(alignment: .topTrailing) {
      if node.isBranch {
        Image(systemName: "chevron.right.circle.fill")
          .font(.system(size: 15))
          .symbolRenderingMode(.palette)
          .foregroundStyle(.white, Theme.accent)
          .offset(x: 3, y: -3)
          .accessibilityHidden(true)
      }
    }
    .opacity(node.isEnabled ? 1 : 0.45)
    .scaleEffect(hovered ? 1.12 : 1)
    .animation(.easeOut(duration: 0.08), value: hovered)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      node.isBranch ? "\(node.title), opens more options"
        : node.opensEditor ? "\(node.title), opens an editor" : node.title)
    .accessibilityHint(node.disabledReason ?? "")
    .accessibilityAddTraits(.isButton)
  }
}

/// The arc that fills while you hold over a branch, so nobody has to guess that holding works.
private struct DwellRing: View {
  let active: Bool
  let dwell: TimeInterval
  let diameter: CGFloat

  var body: some View {
    Circle()
      .trim(from: 0, to: active ? 1 : 0)
      .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
      .rotationEffect(.degrees(-90))
      .frame(width: diameter, height: diameter)
      .opacity(active ? 1 : 0)
      .animation(active ? .linear(duration: dwell) : .easeOut(duration: 0.08), value: active)
      .allowsHitTesting(false)
  }
}

private struct CentreBadge: View {
  @ObservedObject var model: WheelModel
  let radius: Double

  /// What the centre says: the hovered button's state, else where you are.
  private var caption: String {
    if let node = model.hoveredNode {
      if node.isEnabled { return node.isBranch ? "Hold to open" : "Release to run" }
      return (node.disabledReason ?? "").hasPrefix("Needs") ? "Engine missing" : "Coming soon"
    }
    if model.dwellTarget == .centre { return "Going back" }
    return model.breadcrumb.last ?? "Hold a choice"
  }

  var body: some View {
    VStack(spacing: 2) {
      if model.canGoBack {
        Image(systemName: "chevron.left.circle.fill")
          .font(.system(size: 22))
          .symbolRenderingMode(.palette)
          .foregroundStyle(.white, Theme.accent)
          .accessibilityLabel("Back")
      } else if let icon = model.icon {
        Image(nsImage: icon).resizable().frame(width: 34, height: 34)
          .overlay(alignment: .topTrailing) {
            if model.fileCount > 1 {
              Text("\(model.fileCount)")
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Theme.accent, in: Capsule())
                .foregroundStyle(.white)
                .offset(x: 8, y: -6)
            }
          }
      }
      Text(caption)
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
    .frame(width: radius * 2 - 8, height: radius * 2 - 8)
    .modifier(GlassCircle(tint: nil, strong: false))
    .overlay {
      DwellRing(
        active: model.dwellTarget == .centre, dwell: model.dwell, diameter: radius * 2 - 2)
    }
  }
}

/// Liquid Glass on macOS 26, a material with a hairline edge before that.
private struct GlassCircle: ViewModifier {
  let tint: Color?
  let strong: Bool

  func body(content: Content) -> some View {
    if #available(macOS 26.0, *) {
      content.glassEffect(.regular.tint(tint?.opacity(0.85)), in: Circle())
    } else {
      content
        .background(.ultraThinMaterial, in: Circle())
        .background(Circle().fill((tint ?? .clear).opacity(strong ? 0.8 : 0)))
        .overlay(Circle().stroke(.white.opacity(0.22), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }
  }
}
