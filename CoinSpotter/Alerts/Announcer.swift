import AVFoundation
import AudioToolbox

/// Speaks alerts. While the glasses are worn they are the phone's Bluetooth
/// audio output, so the voice comes out of the glasses' speakers.
@MainActor
final class Announcer {
  private let synthesizer = AVSpeechSynthesizer()

  /// Call before streaming starts so speech keeps working with the phone locked.
  func prepare() {
    let audio = AVAudioSession.sharedInstance()
    try? audio.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
    try? audio.setActive(true)
  }

  func say(_ text: String) {
    let utterance = AVSpeechUtterance(string: text)
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate
    synthesizer.speak(utterance)
  }

  func announce(_ sighting: Sighting) {
    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
    say("\(sighting.confirmed ? "Coin" : "Possible coin"), \(sighting.position).")
  }
}
