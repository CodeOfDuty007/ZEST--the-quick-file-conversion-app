import AVFoundation
import CoreMedia
import Foundation
import UniformTypeIdentifiers

/// Describes an audio or video file: a metadata table, not a transcript.
enum MediaReader {
  static func read(url: URL, type: UTType) async throws -> Document {
    let asset = AVURLAsset(url: url)
    let isVideo = type.conforms(to: .movie) || type.conforms(to: .video)
    let name = url.lastPathComponent
    var rows: [(String, String)] = []

    let duration: CMTime
    let common: [AVMetadataItem]
    let videoTracks: [AVAssetTrack]
    let audioTracks: [AVAssetTrack]
    do {
      duration = try await asset.load(.duration)
      common = (try? await asset.load(.commonMetadata)) ?? []
      videoTracks = try await asset.loadTracks(withMediaType: .video)
      audioTracks = try await asset.loadTracks(withMediaType: .audio)
    } catch {
      throw BackendError.unreadable(url)
    }
    guard duration.isNumeric, duration.seconds.isFinite, !(videoTracks.isEmpty && audioTracks.isEmpty)
    else { throw BackendError.unreadable(url) }

    rows.append(("Type", type.localizedDescription ?? type.identifier))
    rows.append(("Duration", formatDuration(duration.seconds)))
    if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
      rows.append(("File size", ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))
    }

    if isVideo, let track = videoTracks.first {
      if let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        rows.append(("Dimensions", "\(Int(abs(rect.width).rounded())) x \(Int(abs(rect.height).rounded())) px"))
      }
      if let fps = try? await track.load(.nominalFrameRate), fps > 0 {
        rows.append(("Frame rate", String(format: "%g fps", (fps * 100).rounded() / 100)))
      }
      if let code = await codec(of: track) { rows.append(("Video codec", code)) }
      if let audio = audioTracks.first, let code = await codec(of: audio) {
        rows.append(("Audio codec", code))
      }
    }
    if let track = audioTracks.first {
      if let code = await codec(of: track), !isVideo { rows.append(("Codec", code)) }
      if let descriptions = try? await track.load(.formatDescriptions),
        let description = descriptions.first,
        let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
      {
        if basic.mSampleRate > 0 { rows.append(("Sample rate", String(format: "%g Hz", basic.mSampleRate))) }
        if basic.mChannelsPerFrame > 0 { rows.append(("Channels", "\(basic.mChannelsPerFrame)")) }
      }
    }

    var title = ""
    for (key, label) in [
      (AVMetadataKey.commonKeyTitle, "Title"), (.commonKeyArtist, "Artist"),
      (.commonKeyAlbumName, "Album"), (.commonKeyCreationDate, "Created"),
    ] {
      guard
        let item = AVMetadataItem.metadataItems(from: common, withKey: key, keySpace: .common).first,
        let value = await metadataString(item), !value.isEmpty
      else { continue }
      if label == "Title" { title = value }
      rows.append((label, value))
    }

    let base = url.deletingPathExtension().lastPathComponent
    let blocks: [Block] = [
      .heading(1, Inline.plain(title.isEmpty ? name : title)),
      .media(video: isVideo, name: name, src: name),
      .table(
        header: [Inline.plain("Property"), Inline.plain("Value")],
        rows: rows.map { [Inline.plain($0.0), Inline.plain($0.1)] }),
      .paragraph(
        Inline.plain(
          "This is a description of the file, not a transcript of its \(isVideo ? "video" : "audio")."
        )),
    ]
    return Document(title: title.isEmpty ? base : title, blocks: blocks)
  }

  private static func metadataString(_ item: AVMetadataItem) async -> String? {
    if let date = try? await item.load(.dateValue) {
      return date.formatted(date: .abbreviated, time: .shortened)
    }
    return (try? await item.load(.stringValue))?.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func codec(of track: AVAssetTrack) async -> String? {
    guard let descriptions = try? await track.load(.formatDescriptions),
      let description = descriptions.first
    else { return nil }
    return fourCC(CMFormatDescriptionGetMediaSubType(description))
  }

  private static func fourCC(_ code: FourCharCode) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
    let printable = bytes.allSatisfy { $0 >= 32 && $0 < 127 }
    return printable ? String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces) : "\(code)"
  }

  private static func formatDuration(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    let clock = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    return seconds < 60 ? String(format: "%.1f s", seconds) : clock
  }
}
