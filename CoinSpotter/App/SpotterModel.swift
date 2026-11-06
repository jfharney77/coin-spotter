import AVFoundation
import MWDATCamera
import MWDATCore
import MWDATMockDevice
import Observation
import SwiftUI
import UIKit

/// Owns the glasses connection, the camera stream and the detection pipeline,
/// and exposes what the screens show.
@Observable
@MainActor
final class SpotterModel {
  // MARK: Glasses

  var registrationState: RegistrationState
  var hasActiveDevice = false
  var sessionState: DeviceSessionState = .idle
  var streamState: StreamState = .stopped
  var askBeforeCameraPermission = false

  // MARK: Detection

  var preview: UIImage?
  var candidates: [Candidate] = []
  var lastSighting: Sighting?
  var framesAnalyzed = 0
  var claudeRequests = 0
  var coinsFound = 0
  var activity = "Not running"

  // MARK: Settings

  var apiKey: String { didSet { KeyStore.save(apiKey); applyVerifier() } }
  var confirmWithClaude: Bool {
    didSet { UserDefaults.standard.set(confirmWithClaude, forKey: "confirmWithClaude"); applyVerifier() }
  }
  var claudeModel: ClaudeModel {
    didSet { UserDefaults.standard.set(claudeModel.rawValue, forKey: "claudeModel"); applyVerifier() }
  }
  var testModeOn = false

  // MARK: Errors

  var errorMessage = ""
  var showError = false

  var isRegistered: Bool { registrationState == .registered }
  var isRunning: Bool {
    switch sessionState {
    case .starting, .started, .paused, .stopping: return true
    case .idle, .stopped: return false
    }
  }
  var needsApiKey: Bool { confirmWithClaude && apiKey.isEmpty }

  @ObservationIgnored private let wearables: WearablesInterface
  @ObservationIgnored private let deviceSelector: AutoDeviceSelector
  @ObservationIgnored private var deviceSession: DeviceSession?
  @ObservationIgnored private var camera: MWDATCamera.Camera?
  @ObservationIgnored private let sessionTokens = ListenerTokenBag()
  @ObservationIgnored private let streamTokens = ListenerTokenBag()
  @ObservationIgnored private let decoder = FrameDecoder()
  @ObservationIgnored private let gate = FrameGate()
  @ObservationIgnored private let announcer = Announcer()
  @ObservationIgnored private var pipeline: CoinPipeline!

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    self.deviceSelector = AutoDeviceSelector(wearables: wearables)
    self.registrationState = wearables.registrationState
    self.apiKey = KeyStore.load()
    self.confirmWithClaude = UserDefaults.standard.object(forKey: "confirmWithClaude") as? Bool ?? true
    self.claudeModel =
      UserDefaults.standard.string(forKey: "claudeModel").flatMap(ClaudeModel.init(rawValue:)) ?? .opus

    self.pipeline = CoinPipeline { [weak self] event in
      Task { @MainActor in self?.handle(event) }
    }
    applyVerifier()

    Task { [weak self] in
      for await state in wearables.registrationStateStream() {
        self?.registrationState = state
      }
    }
    let selector = deviceSelector
    Task { [weak self] in
      for await device in selector.activeDeviceStream() {
        self?.hasActiveDevice = device != nil
      }
    }
  }

  // MARK: Registration with the Meta AI app

  func connectGlasses() {
    guard registrationState != .registering else { return }
    Task {
      do { try await wearables.startRegistration() } catch { report(error) }
    }
  }

  func disconnectGlasses() {
    stop()
    Task {
      do { try await wearables.startUnregistration() } catch { report(error) }
    }
  }

  /// Meta AI returns to the app through the coinspotter:// URL scheme.
  func handleCallback(_ url: URL) {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true
    else { return }
    Task {
      do { _ = try await wearables.handleUrl(url) } catch { report(error) }
    }
  }

  // MARK: Start and stop

  func start() {
    guard !isRunning else { return }
    announcer.prepare()
    do {
      let session = try wearables.createSession(deviceSelector: deviceSelector)
      deviceSession = session
      // Subscribe before start() so no state change is missed.
      session.statePublisher.listen { [weak self] state in
        Task { @MainActor in self?.sessionChanged(to: state) }
      }.store(in: sessionTokens)
      session.errorPublisher.listen { [weak self] error in
        Task { @MainActor in self?.reportText(error.localizedDescription) }
      }.store(in: sessionTokens)
      sessionState = .starting
      activity = "Connecting to glasses"
      try session.start()
    } catch {
      report(error)
      sessionState = .idle
      endSession()
    }
  }

  func stop() {
    guard let session = deviceSession else { return }
    sessionState = .stopping
    session.stop()
  }

  private func sessionChanged(to state: DeviceSessionState) {
    sessionState = state
    switch state {
    case .started:
      Task { await startCameraIfAllowed() }
    case .paused:
      activity = "Paused by the glasses"
    case .stopped:
      endSession()
    default:
      break
    }
  }

  private func endSession() {
    endStream()
    sessionTokens.clear()
    deviceSession = nil
    activity = "Not running"
  }

  // MARK: Camera

  private func startCameraIfAllowed() async {
    guard camera == nil else { return }
    do {
      if try await wearables.checkPermissionStatus(.camera) == .granted {
        startCamera()
      } else {
        // Asking switches to the Meta AI app, so confirm first.
        askBeforeCameraPermission = true
      }
    } catch {
      report(error)
    }
  }

  func requestCameraPermission() async {
    do {
      guard try await wearables.requestPermission(.camera) == .granted else {
        reportText("Camera access was not granted, so coins cannot be spotted.")
        stop()
        return
      }
      startCamera()
    } catch {
      report(error)
    }
  }

  private func startCamera() {
    guard camera == nil, let session = deviceSession, session.state == .started else { return }
    // HEVC keeps streaming with the phone locked; the raw codec pauses in the background.
    let config = StreamConfiguration(
      videoCodec: VideoCodec.hvc1,
      resolution: StreamingResolution.high,
      frameRate: Tuning.streamFrameRate)
    do {
      guard let newCamera = try session.addCamera(config: config) else {
        reportText("The glasses camera could not be started. Try again.")
        return
      }
      camera = newCamera
      listen(to: newCamera.stream)
      streamState = .starting
      newCamera.stream.start()
    } catch {
      report(error)
    }
  }

  private func listen(to stream: MWDATCamera.Stream) {
    stream.statePublisher.listen { [weak self] state in
      Task { @MainActor in self?.streamChanged(to: state) }
    }.store(in: streamTokens)

    stream.errorPublisher.listen { [weak self] error in
      Task { @MainActor in self?.reportText(error.localizedDescription) }
    }.store(in: streamTokens)

    // Runs off the main thread. Every frame is decoded (HEVC frames depend on
    // the ones before); the gate then decides which decoded frames are analysed.
    let decoder = self.decoder
    let gate = self.gate
    let pipeline = self.pipeline!
    stream.videoFramePublisher.listen { frame in
      guard let pixelBuffer = decoder.decode(frame.sampleBuffer), gate.tryEnter() else { return }
      Task {
        await pipeline.analyze(pixelBuffer)
        gate.leave()
      }
    }.store(in: streamTokens)
  }

  private func streamChanged(to state: StreamState) {
    streamState = state
    switch state {
    case .streaming:
      activity = "Watching for coins"
    case .paused:
      activity = "Paused by the glasses"
    case .stopped:
      endStream()
    default:
      break
    }
  }

  private func endStream() {
    streamTokens.clear()
    camera?.stop()
    camera = nil
    streamState = .stopped
    preview = nil
    candidates = []
  }

  // MARK: Detection results

  private func handle(_ event: PipelineEvent) {
    switch event {
    case .analyzed(let image, let found):
      framesAnalyzed += 1
      candidates = found
      if let image { preview = UIImage(cgImage: image) }
    case .checking(let count):
      claudeRequests += 1
      activity = "Asking Claude about \(count) possible coin\(count == 1 ? "" : "s")"
    case .sighting(let sighting):
      coinsFound += 1
      lastSighting = sighting
      activity = "Coin spotted"
      announcer.announce(sighting)
    case .dismissed:
      activity = "Watching for coins"
    case .problem(let message):
      activity = message
    }
  }

  /// The preview is only rendered while the app is on screen.
  func setOnScreen(_ onScreen: Bool) {
    Task { await pipeline.setWantsPreview(onScreen) }
  }

  func testAlert() {
    announcer.prepare()
    announcer.say("Coin, straight ahead, near your feet.")
  }

  private func applyVerifier() {
    let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let mode: CoinPipeline.Mode
    if !confirmWithClaude {
      mode = .phoneOnly
    } else if key.isEmpty {
      // Nothing is announced until a key is entered; the screen asks for it.
      mode = .filterOnly
    } else {
      mode = .confirm(ClaudeVerifier(apiKey: key, model: claudeModel))
    }
    Task { await pipeline.setMode(mode) }
  }

  // MARK: Test mode (phone camera stands in for the glasses)

  func setTestMode(_ on: Bool) async {
    let kit = MockDeviceKit.shared
    guard on else {
      stop()
      await kit.disable()
      testModeOn = false
      return
    }
    guard await AVCaptureDevice.requestAccess(for: .video) else {
      reportText("Test mode needs the phone camera. Allow it in iOS Settings.")
      return
    }
    do {
      kit.enable()
      let glasses = try kit.pairGlasses(model: .rayBanMeta)
      glasses.powerOn()
      glasses.unfold()
      glasses.don()
      glasses.services.camera.setCameraFeed(cameraFacing: .back)
      testModeOn = true
    } catch {
      await kit.disable()
      report(error)
    }
  }

  // MARK: Errors

  private func report(_ error: Error) {
    reportText(error.localizedDescription)
  }

  private func reportText(_ message: String) {
    errorMessage = message
    showError = true
  }
}
