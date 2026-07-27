import AVFoundation

struct TimothySpeechRoute: Equatable {
  let name: String
  let isBluetooth: Bool

  static let phone = TimothySpeechRoute(name: "iPhone speaker", isBluetooth: false)
}

enum TimothySpeechSettings {
  static let voiceIdentifierKey = "timothySpeechVoiceIdentifier"
  static let automaticallySpeakKey = "timothyAutomaticallySpeakAnswers"
  static let automaticVoiceIdentifier = "automatic"

  static func installedVoices(language: String) -> [AVSpeechSynthesisVoice] {
    let languageCode = language == "zh" ? "zh-TW" : "en-US"
    return AVSpeechSynthesisVoice.speechVoices()
      .filter { $0.language == languageCode }
      .sorted {
        if $0.quality != $1.quality {
          return $0.quality.rawValue > $1.quality.rawValue
        }
        return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
      }
  }

  static func selectedVoice(language: String) -> AVSpeechSynthesisVoice? {
    let identifier = UserDefaults.standard.string(forKey: voiceIdentifierKey)
      ?? automaticVoiceIdentifier
    if identifier != automaticVoiceIdentifier,
       let selected = AVSpeechSynthesisVoice(identifier: identifier),
       selected.language == (language == "zh" ? "zh-TW" : "en-US") {
      return selected
    }
    return installedVoices(language: language).first
      ?? AVSpeechSynthesisVoice(language: language == "zh" ? "zh-TW" : "en-US")
  }

  static var automaticallySpeaksAnswers: Bool {
    if UserDefaults.standard.object(forKey: automaticallySpeakKey) == nil {
      return true
    }
    return UserDefaults.standard.bool(forKey: automaticallySpeakKey)
  }
}

@MainActor
final class SpeechOutputController: NSObject, @preconcurrency AVSpeechSynthesizerDelegate {
  var onFinished: (() -> Void)?
  var onRouteChange: ((TimothySpeechRoute) -> Void)?

  private let synthesizer = AVSpeechSynthesizer()
  private var activeUtterance: AVSpeechUtterance?

  override init() {
    super.init()
    synthesizer.delegate = self
    synthesizer.usesApplicationAudioSession = true
  }

  func speak(_ text: String, language: String) {
    configureAudioRoute()

    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = TimothySpeechSettings.selectedVoice(language: language)
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
    utterance.pitchMultiplier = 1.0

    activeUtterance = utterance
    synthesizer.stopSpeaking(at: .immediate)
    synthesizer.speak(utterance)
  }

  func stop() {
    activeUtterance = nil
    synthesizer.stopSpeaking(at: .immediate)
  }

  func refreshRoute() {
    onRouteChange?(Self.currentRoute())
  }

  private func configureAudioRoute() {
    let audioSession = AVAudioSession.sharedInstance()
    do {
      try audioSession.setCategory(
        .playAndRecord,
        mode: .voicePrompt,
        options: [.allowBluetoothHFP, .defaultToSpeaker, .duckOthers]
      )
      try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

      if let glassesInput = audioSession.availableInputs?.first(where: {
        $0.portType == .bluetoothHFP
      }) {
        // Selecting an HFP input also selects its matching Bluetooth output.
        try audioSession.setPreferredInput(glassesInput)
      }
    } catch {
      NSLog("[Hithe] Unable to select Bluetooth speech route: \(error.localizedDescription)")
    }
    onRouteChange?(Self.currentRoute())
  }

  private static func currentRoute() -> TimothySpeechRoute {
    guard let output = AVAudioSession.sharedInstance().currentRoute.outputs.first else {
      return .phone
    }
    let bluetoothTypes: Set<AVAudioSession.Port> = [
      .bluetoothHFP,
      .bluetoothA2DP,
      .bluetoothLE,
    ]
    let isBluetooth = bluetoothTypes.contains(output.portType)
    return TimothySpeechRoute(
      name: isBluetooth ? output.portName : "iPhone speaker",
      isBluetooth: isBluetooth
    )
  }

  func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didFinish utterance: AVSpeechUtterance
  ) {
    finishIfCurrent(utterance)
  }

  func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didCancel utterance: AVSpeechUtterance
  ) {
    finishIfCurrent(utterance)
  }

  private func finishIfCurrent(_ utterance: AVSpeechUtterance) {
    guard utterance === activeUtterance else { return }
    activeUtterance = nil
    onFinished?()
  }
}
