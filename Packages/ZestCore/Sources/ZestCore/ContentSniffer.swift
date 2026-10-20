import Foundation
import UniformTypeIdentifiers

/// Identifies a file by magic bytes first and falls back to the extension (routing rule 1).
public enum ContentSniffer {
  public static func type(ofFileAt url: URL) -> UTType? {
    var head = Data()
    if let handle = try? FileHandle(forReadingFrom: url) {
      head = (try? handle.read(upToCount: 64)) ?? Data()
      try? handle.close()
    }
    var byExtension = UTType(filenameExtension: url.pathExtension.lowercased())
    // `.m4a` maps to com.apple.m4a-audio; use the canonical type the router and wheel use.
    if let ext = byExtension, ext.conforms(to: .mpeg4Audio) { byExtension = .mpeg4Audio }
    if let sniffed = type(ofHeader: head) {
      // Generic MP4 brands (isom, mp42…) are used by audio-only files too. The header
      // cannot tell them apart without parsing tracks, so a matching audio extension wins.
      if sniffed == .mpeg4Movie, let byExtension, byExtension.conforms(to: .audio) {
        return byExtension
      }
      // Word, Excel, Pages, EPUB and many more are ZIP files underneath. Their extension says
      // which, the header cannot, so a specific extension beats the generic ZIP signature.
      if sniffed == .zip, let byExtension, byExtension != .zip { return byExtension }
      return sniffed
    }
    return byExtension
  }

  public static func type(ofHeader data: Data) -> UTType? {
    let b = [UInt8](data.prefix(64))
    func starts(_ sig: [UInt8], at offset: Int = 0) -> Bool {
      b.count >= offset + sig.count && Array(b[offset..<offset + sig.count]) == sig
    }
    func ascii(_ s: String, at offset: Int = 0) -> Bool { starts(Array(s.utf8), at: offset) }

    if starts([0x89, 0x50, 0x4E, 0x47]) { return .png }
    if starts([0xFF, 0xD8, 0xFF]) { return .jpeg }
    if ascii("GIF8") { return .gif }
    if ascii("%PDF") { return .pdf }
    if starts([0x50, 0x4B, 0x03, 0x04]) { return .zip }
    if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) { return .tiff }
    if ascii("BM") { return .bmp }
    if ascii("RIFF") && ascii("WEBP", at: 8) { return .webP }
    if ascii("RIFF") && ascii("WAVE", at: 8) { return .wav }
    if ascii("RIFF") && ascii("AVI ", at: 8) { return .avi }
    if ascii("FORM") && ascii("AIFF", at: 8) { return .aiff }
    if ascii("fLaC") { return Formats.flac }
    if ascii("OggS") {
      // Opus lives inside an Ogg container; its first packet starts with "OpusHead".
      let marker = Array("OpusHead".utf8)
      let isOpus = b.indices.contains { i in
        i + marker.count <= b.count && Array(b[i..<i + marker.count]) == marker
      }
      return isOpus ? Formats.opus : Formats.ogg
    }
    if ascii("ID3") || starts([0xFF, 0xFB]) || starts([0xFF, 0xF3]) { return .mp3 }
    if starts([0x1A, 0x45, 0xDF, 0xA3]) {
      // WebM and Matroska share an EBML header; only the DocType string differs.
      let doctype = Array("webm".utf8)
      let isWebM = b.indices.contains { i in
        i + doctype.count <= b.count && Array(b[i..<i + doctype.count]) == doctype
      }
      return isWebM ? Formats.webm : Formats.mkv
    }
    if ascii("ftyp", at: 4), b.count >= 12 {
      let brand = String(decoding: b[8..<12], as: UTF8.self)
      switch brand {
      case "heic", "heix", "hevc", "mif1", "msf1": return .heic
      case "avif", "avis": return Formats.avif
      case "qt  ": return .quickTimeMovie
      case "M4A ", "M4B ": return .mpeg4Audio
      default: return .mpeg4Movie
      }
    }
    return nil
  }
}
