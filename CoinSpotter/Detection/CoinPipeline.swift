import CoreGraphics
import CoreVideo
import Foundation

struct Sighting {
  let position: String
  /// True when Claude confirmed it; false in on-phone-only mode.
  let confirmed: Bool
  let time: Date
  /// The enlarged crop that triggered the alert, as JPEG.
  let crop: Data?
}

enum PipelineEvent {
  case analyzed(preview: CGImage?, candidates: [Candidate])
  case checking(count: Int)
  case sighting(Sighting)
  case dismissed
  case problem(String)
}

/// Lets one frame at a time into the pipeline and enforces the analysis interval,
/// so a slow frame is dropped instead of queued.
final class FrameGate: @unchecked Sendable {
  private let lock = NSLock()
  private var busy = false
  private var lastEntry = Date.distantPast

  func tryEnter() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let now = Date()
    guard !busy, now.timeIntervalSince(lastEntry) >= Tuning.analysisInterval else { return false }
    busy = true
    lastEntry = now
    return true
  }

  func leave() {
    lock.lock()
    busy = false
    lock.unlock()
  }
}

/// Frame in, alert out: on-phone filter first, then Claude for anything that passes.
actor CoinPipeline {
  private let finder = CandidateFinder()
  private let emit: @Sendable (PipelineEvent) -> Void
  enum Mode {
    /// Run the filter and show its boxes, but never alert.
    case filterOnly
    /// Alert on the on-phone filter alone ("possible coin").
    case phoneOnly
    /// Alert only when Claude agrees.
    case confirm(ClaudeVerifier)
  }

  private var mode = Mode.filterOnly
  private var wantsPreview = true
  private var verifying = false
  private var lastVerification = Date.distantPast
  private var recentVerifications: [Date] = []
  private var quietUntil = Date.distantPast

  init(emit: @escaping @Sendable (PipelineEvent) -> Void) {
    self.emit = emit
  }

  func setMode(_ mode: Mode) {
    self.mode = mode
  }

  func setWantsPreview(_ wantsPreview: Bool) {
    self.wantsPreview = wantsPreview
  }

  func analyze(_ pixelBuffer: CVPixelBuffer) {
    let candidates = finder.candidates(in: pixelBuffer)
    emit(.analyzed(preview: wantsPreview ? finder.preview(of: pixelBuffer) : nil, candidates: candidates))

    let now = Date()
    guard let strongest = candidates.first, now >= quietUntil else { return }

    let verifier: ClaudeVerifier
    switch mode {
    case .filterOnly:
      return
    case .phoneOnly:
      quietUntil = now.addingTimeInterval(Tuning.alertCooldown)
      emit(
        .sighting(
          Sighting(
            position: strongest.spokenPosition, confirmed: false, time: now,
            crop: finder.crop(strongest, from: pixelBuffer))))
      return
    case .confirm(let chosen):
      verifier = chosen
    }

    guard !verifying, now.timeIntervalSince(lastVerification) >= Tuning.verifyInterval else { return }
    recentVerifications.removeAll { now.timeIntervalSince($0) > 3600 }
    guard recentVerifications.count < Tuning.maxVerificationsPerHour else { return }

    var checked: [Candidate] = []
    var crops: [Data] = []
    for candidate in candidates {
      if let crop = finder.crop(candidate, from: pixelBuffer) {
        checked.append(candidate)
        crops.append(crop)
      }
    }
    guard !crops.isEmpty else { return }

    verifying = true
    lastVerification = now
    recentVerifications.append(now)
    emit(.checking(count: crops.count))
    // Runs on its own so new frames keep being filtered while Claude answers.
    Task { await self.verify(checked, crops: crops, with: verifier) }
  }

  private func verify(_ candidates: [Candidate], crops: [Data], with verifier: ClaudeVerifier) async {
    defer { verifying = false }
    do {
      let coins = try await verifier.coinIndices(in: crops)
      guard let first = coins.min() else {
        emit(.dismissed)
        return
      }
      quietUntil = Date().addingTimeInterval(Tuning.alertCooldown)
      emit(
        .sighting(
          Sighting(
            position: candidates[first].spokenPosition, confirmed: true, time: Date(),
            crop: crops[first])))
    } catch {
      emit(.problem(error.localizedDescription))
    }
  }
}
