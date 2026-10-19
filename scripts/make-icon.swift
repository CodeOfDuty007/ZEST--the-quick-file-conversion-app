// Draws the Zest app icon (an orange-slice wheel) and writes the AppIcon.appiconset.
// Usage: swift scripts/make-icon.swift App/Zest/Resources/Assets.xcassets/AppIcon.appiconset
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
  CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func draw(into ctx: CGContext, size s: CGFloat) {
  let k = s / 1024
  ctx.scaleBy(x: k, y: k)

  // Tile: 824 pt squircle centred in the 1024 canvas, with a soft drop shadow.
  let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
  let path = CGPath(roundedRect: tile, cornerWidth: 190, cornerHeight: 190, transform: nil)
  ctx.saveGState()
  ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: color(90, 35, 0, 0.35))
  ctx.addPath(path)
  ctx.setFillColor(color(240, 120, 20))
  ctx.fillPath()
  ctx.restoreGState()

  ctx.saveGState()
  ctx.addPath(path)
  ctx.clip()
  let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [color(255, 166, 72), color(238, 108, 14)] as CFArray, locations: [0, 1])!
  ctx.drawLinearGradient(
    gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

  let c = CGPoint(x: 512, y: 512)
  func circle(_ r: CGFloat, _ fill: CGColor) {
    ctx.setFillColor(fill)
    ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
  }

  // Rind, pith, then eight juicy segments separated by cream membranes.
  circle(318, color(255, 247, 222))
  circle(282, color(255, 226, 150))
  let segments = 8
  let gap = 0.085  // radians of membrane between segments
  for i in 0..<segments {
    let start = Double(i) * 2 * .pi / Double(segments) + gap / 2 - .pi / 2
    let end = Double(i + 1) * 2 * .pi / Double(segments) - gap / 2 - .pi / 2
    let seg = CGMutablePath()
    seg.move(to: CGPoint(x: c.x + 52 * cos(start), y: c.y + 52 * sin(start)))
    seg.addArc(center: c, radius: 262, startAngle: start, endAngle: end, clockwise: false)
    seg.addLine(to: CGPoint(x: c.x + 52 * cos(end), y: c.y + 52 * sin(end)))
    seg.addArc(center: c, radius: 52, startAngle: end, endAngle: start, clockwise: true)
    seg.closeSubpath()
    ctx.addPath(seg)
    ctx.setFillColor(i % 2 == 0 ? color(255, 150, 40) : color(255, 176, 66))
    ctx.fillPath()
  }
  circle(46, color(255, 247, 222))

  // Gloss on the upper-left of the rind.
  ctx.setStrokeColor(color(255, 255, 255, 0.55))
  ctx.setLineWidth(14)
  ctx.setLineCap(.round)
  ctx.addArc(center: c, radius: 300, startAngle: .pi * 0.62, endAngle: .pi * 0.86, clockwise: false)
  ctx.strokePath()
  ctx.restoreGState()
}

func render(size: Int) -> CGImage {
  let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.interpolationQuality = .high
  draw(into: ctx, size: CGFloat(size))
  return ctx.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
  let dest = CGImageDestinationCreateWithURL(
    url as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(dest, image, nil)
  precondition(CGImageDestinationFinalize(dest), "could not write \(url.path)")
}

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

var images: [[String: String]] = []
for (point, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
  for scale in scales {
    let name = "icon_\(point)x\(point)@\(scale)x.png"
    write(render(size: point * scale), to: directory.appendingPathComponent(name))
    images.append([
      "idiom": "mac", "size": "\(point)x\(point)", "scale": "\(scale)x", "filename": name,
    ])
  }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(
  withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: directory.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icons to \(directory.path)")
