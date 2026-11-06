import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Turns the glasses' compressed HEVC frames into pixel buffers.
///
/// The stream is requested as HEVC because that is the only codec the SDK keeps
/// delivering while the app is in the background (phone locked, in a pocket).
/// Frames must be fed in order; the SDK's frame callback does that.
final class FrameDecoder: @unchecked Sendable {
  private final class Output: @unchecked Sendable {
    var pixelBuffer: CVPixelBuffer?
  }

  private let lock = NSLock()
  private var session: VTDecompressionSession?
  private var format: CMFormatDescription?
  private var awaitingKeyframe = true
  private var consecutiveFailures = 0

  func decode(_ sampleBuffer: CMSampleBuffer) -> CVPixelBuffer? {
    // A raw (already decoded) stream carries the pixels directly.
    if let ready = CMSampleBufferGetImageBuffer(sampleBuffer) { return ready }
    guard CMSampleBufferGetDataBuffer(sampleBuffer) != nil,
      let frameFormat = CMSampleBufferGetFormatDescription(sampleBuffer)
    else { return nil }

    lock.lock()
    defer { lock.unlock() }

    if let current = session, let currentFormat = format,
      !CMFormatDescriptionEqual(currentFormat, otherFormatDescription: frameFormat)
        || !VTDecompressionSessionCanAcceptFormatDescription(current, formatDescription: frameFormat)
    {
      reset()
    }
    if session == nil {
      // Software decoding survives the app going to the background; iOS tears
      // down hardware decoder sessions there.
      let decoderSpec =
        [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: false] as CFDictionary
      let attributes = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] as CFDictionary
      var created: VTDecompressionSession?
      VTDecompressionSessionCreate(
        allocator: kCFAllocatorDefault,
        formatDescription: frameFormat,
        decoderSpecification: decoderSpec,
        imageBufferAttributes: attributes,
        outputCallback: nil,
        decompressionSessionOut: &created)
      session = created
      format = frameFormat
      awaitingKeyframe = true
    }
    guard let session else { return nil }

    // A fresh decoder can only start from a keyframe.
    let isKeyframe = Self.isKeyframe(sampleBuffer)
    if awaitingKeyframe && !isKeyframe { return nil }

    // No asynchronous flag is set, so the handler runs before the call returns.
    let output = Output()
    let status = VTDecompressionSessionDecodeFrame(
      session, sampleBuffer: sampleBuffer, flags: [], infoFlagsOut: nil
    ) { status, _, imageBuffer, _, _ in
      if status == noErr { output.pixelBuffer = imageBuffer }
    }
    guard status == noErr, let pixelBuffer = output.pixelBuffer else {
      consecutiveFailures += 1
      if consecutiveFailures >= 3 { reset() }
      return nil
    }
    consecutiveFailures = 0
    awaitingKeyframe = false
    return pixelBuffer
  }

  private func reset() {
    if let session { VTDecompressionSessionInvalidate(session) }
    session = nil
    format = nil
    consecutiveFailures = 0
    awaitingKeyframe = true
  }

  /// HEVC keyframes are NAL unit types 16-21. Units are length-prefixed (4 bytes, big endian).
  private static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
    guard let data = CMSampleBufferGetDataBuffer(sampleBuffer) else { return false }
    let total = CMBlockBufferGetDataLength(data)
    var offset = 0
    while offset + 4 < total {
      var lengthBigEndian: UInt32 = 0
      guard
        CMBlockBufferCopyDataBytes(data, atOffset: offset, dataLength: 4, destination: &lengthBigEndian)
          == kCMBlockBufferNoErr
      else { return false }
      let length = Int(UInt32(bigEndian: lengthBigEndian))
      offset += 4
      guard length > 0, offset + length <= total else { return false }
      var header: UInt8 = 0
      guard
        CMBlockBufferCopyDataBytes(data, atOffset: offset, dataLength: 1, destination: &header)
          == kCMBlockBufferNoErr
      else { return false }
      if (16...21).contains((header >> 1) & 0x3F) { return true }
      offset += length
    }
    return false
  }
}
