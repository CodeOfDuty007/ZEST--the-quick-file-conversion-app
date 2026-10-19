import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Loads pixels the way a viewer shows them: EXIF orientation applied. Phone photos
/// store rotated rasters with an orientation tag, so skipping this turns them sideways.
public enum OrientedImage {
  public static func load(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
    let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      // Full size: the "thumbnail" is only the route to an oriented image.
      kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1),
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
      ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
  }

  /// Redraws into 8-bit sRGB so encoders that ignore ICC profiles and orientation
  /// (cwebp) still produce the colours and rotation the user sees.
  static func normalizedSRGB(_ image: CGImage) -> CGImage? {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return context.makeImage()
  }

  static func writePNG(_ image: CGImage, to url: URL) -> Bool {
    guard
      let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return false }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination)
  }
}
