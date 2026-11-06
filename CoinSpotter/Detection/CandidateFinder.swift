import CoreImage
import CoreVideo
import Foundation
import ImageIO
import Vision

/// The free, on-phone half of detection: finds small round or elliptical
/// outlines that stand out from the ground. It is deliberately generous;
/// Claude makes the final call.
struct CandidateFinder {
  private let context = CIContext()

  func candidates(in pixelBuffer: CVPixelBuffer) -> [Candidate] {
    let frameWidth = Double(CVPixelBufferGetWidth(pixelBuffer))
    let frameHeight = Double(CVPixelBufferGetHeight(pixelBuffer))
    guard frameWidth > 0, frameHeight > 0 else { return [] }

    let request = VNDetectContoursRequest()
    request.contrastAdjustment = 1.5
    // Vision shrinks to 512 px by default, which would erase distant coins.
    request.maximumImageDimension = Int(max(frameWidth, frameHeight))
    let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
    guard (try? handler.perform([request])) != nil,
      let observation = request.results?.first
    else { return [] }

    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    let luma = LumaSampler(pixelBuffer: pixelBuffer)

    var found: [Candidate] = []
    for index in 0..<observation.contourCount {
      guard let contour = try? observation.contour(at: index),
        (8...600).contains(contour.pointCount)
      else { continue }
      // Vision's points are fractions of the frame with the origin at the bottom left.
      let points = contour.normalizedPoints.map {
        (x: Double($0.x) * frameWidth, y: (1 - Double($0.y)) * frameHeight)
      }
      guard let shape = OutlineShape(points: points), shape.looksLikeCoin(frameWidth: frameWidth) else {
        continue
      }
      let contrast = luma?.contrast(of: shape) ?? 0
      guard contrast >= Tuning.minContrast else { continue }
      found.append(
        Candidate(
          x: shape.minX / frameWidth, y: shape.minY / frameHeight,
          width: shape.width / frameWidth, height: shape.height / frameHeight,
          contrast: contrast))
    }

    // Strongest first, dropping duplicates (a coin's rim often yields two outlines).
    var kept: [Candidate] = []
    for candidate in found.sorted(by: { $0.contrast > $1.contrast }) {
      if kept.count == Tuning.maxCandidatesPerRequest { break }
      if !kept.contains(where: { $0.overlaps(candidate) }) { kept.append(candidate) }
    }
    return kept
  }

  /// A square JPEG around the candidate, enlarged so Claude can see what it is.
  func crop(_ candidate: Candidate, from pixelBuffer: CVPixelBuffer) -> Data? {
    let frameWidth = Double(CVPixelBufferGetWidth(pixelBuffer))
    let frameHeight = Double(CVPixelBufferGetHeight(pixelBuffer))
    let objectSize = max(candidate.width * frameWidth, candidate.height * frameHeight)
    let side = min(max(objectSize * 6, 160), frameWidth, frameHeight)
    let left = min(max(candidate.centerX * frameWidth - side / 2, 0), frameWidth - side)
    let top = min(max(candidate.centerY * frameHeight - side / 2, 0), frameHeight - side)
    // Core Image's origin is at the bottom left.
    let region = CGRect(x: left, y: frameHeight - top - side, width: side, height: side)

    let outputSide = 384.0
    let scale = outputSide / side
    let image = CIImage(cvPixelBuffer: pixelBuffer)
      .cropped(to: region)
      .transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY))
      .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    return context.jpegRepresentation(
      of: image, colorSpace: CGColorSpaceCreateDeviceRGB(),
      options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.85])
  }

  /// A downsized picture of the whole frame for the on-screen preview.
  func preview(of pixelBuffer: CVPixelBuffer) -> CGImage? {
    let image = CIImage(cvPixelBuffer: pixelBuffer)
      .transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
    return context.createCGImage(image, from: image.extent)
  }
}

/// Reads brightness out of a locked BGRA pixel buffer.
private struct LumaSampler {
  let base: UnsafePointer<UInt8>
  let bytesPerRow: Int
  let width: Int
  let height: Int

  init?(pixelBuffer: CVPixelBuffer) {
    guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
      let address = CVPixelBufferGetBaseAddress(pixelBuffer)
    else { return nil }
    base = UnsafePointer(address.assumingMemoryBound(to: UInt8.self))
    bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    width = CVPixelBufferGetWidth(pixelBuffer)
    height = CVPixelBufferGetHeight(pixelBuffer)
  }

  private func luma(x: Double, y: Double) -> Double? {
    let column = Int(x), row = Int(y)
    guard column >= 0, column < width, row >= 0, row < height else { return nil }
    let pixel = base + row * bytesPerRow + column * 4
    return 0.114 * Double(pixel[0]) + 0.587 * Double(pixel[1]) + 0.299 * Double(pixel[2])
  }

  /// Mean brightness inside the outline's ellipse versus a ring of ground around it.
  func contrast(of shape: OutlineShape) -> Double {
    let centerX = shape.minX + shape.width / 2
    let centerY = shape.minY + shape.height / 2
    let radiusX = shape.width / 2, radiusY = shape.height / 2
    var inside = 0.0, insideCount = 0.0
    var outside = 0.0, outsideCount = 0.0
    for step in 0..<16 {
      let angle = Double(step) / 16 * 2 * Double.pi
      let dx = cos(angle), dy = sin(angle)
      for fraction in [0.3, 0.6] {
        if let value = luma(x: centerX + dx * radiusX * fraction, y: centerY + dy * radiusY * fraction) {
          inside += value
          insideCount += 1
        }
      }
      if let value = luma(x: centerX + dx * (radiusX * 1.6 + 2), y: centerY + dy * (radiusY * 1.6 + 2)) {
        outside += value
        outsideCount += 1
      }
    }
    guard insideCount > 0, outsideCount > 0 else { return 0 }
    return abs(inside / insideCount - outside / outsideCount)
  }
}
