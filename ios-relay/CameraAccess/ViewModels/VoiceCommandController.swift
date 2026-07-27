import AVFoundation
import Speech

enum VoiceAssistantState: Equatable {
  case off
  case starting
  case listening
  case hearing
  case thinking
  case speaking

  var label: String {
    switch self {
    case .off: return "Voice assistant off"
    case .starting: return "Starting voice assistant"
    case .listening: return "Listening for Hey Timothy"
    case .hearing: return "Listening to your question"
    case .thinking: return "Timothy is looking"
    case .speaking: return "Timothy is answering"
    }
  }

  var icon: String {
    switch self {
    case .off: return "mic.slash.fill"
    case .starting, .thinking: return "hourglass"
    case .listening: return "mic.fill"
    case .hearing: return "waveform"
    case .speaking: return "speaker.wave.2.fill"
    }
  }
}

enum VoiceCommandError: LocalizedError {
  case speechPermissionDenied
  case microphonePermissionDenied
  case onDeviceRecognitionUnavailable
  case recognitionUnavailable

  var errorDescription: String? {
    switch self {
    case .speechPermissionDenied:
      return "Speech recognition permission is required for Hey Timothy."
    case .microphonePermissionDenied:
      return "Microphone permission is required for Hey Timothy."
    case .onDeviceRecognitionUnavailable:
      return "On-device English speech recognition is unavailable on this iPhone."
    case .recognitionUnavailable:
      return "Speech recognition is temporarily unavailable."
    }
  }
}

@MainActor
final class VoiceCommandController {
  var onStateChange: ((VoiceAssistantState) -> Void)?
  var onCommand: ((String) -> Void)?
  var onError: ((String) -> Void)?

  private let audioEngine = AVAudioEngine()
  private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private var commandDebounceTask: Task<Void, Never>?
  private var activeSessionID: UUID?
  private var inputTapInstalled = false
  private var wantsListening = false
  private var pendingCommand = ""

  func start() async {
    guard !wantsListening else { return }
    setState(.starting)

    do {
      try await requestPermissions()
      wantsListening = true
      try beginRecognition()
    } catch {
      wantsListening = false
      setState(.off)
      onError?(error.localizedDescription)
    }
  }

  func stop() {
    wantsListening = false
    tearDownRecognition()
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    setState(.off)
  }

  func pauseForResponse() {
    guard wantsListening else { return }
    tearDownRecognition()
    setState(.thinking)
  }

  func markSpeaking() {
    guard wantsListening else { return }
    setState(.speaking)
  }

  func resumeAfterResponse() {
    guard wantsListening else { return }
    do {
      try beginRecognition()
    } catch {
      setState(.off)
      onError?(error.localizedDescription)
    }
  }

  private func requestPermissions() async throws {
    let speechStatus: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation {
      continuation in
      SFSpeechRecognizer.requestAuthorization { status in
        continuation.resume(returning: status)
      }
    }
    guard speechStatus == .authorized else {
      throw VoiceCommandError.speechPermissionDenied
    }

    let microphoneAllowed = await AVAudioApplication.requestRecordPermission()
    guard microphoneAllowed else {
      throw VoiceCommandError.microphonePermissionDenied
    }
  }

  private func beginRecognition() throws {
    tearDownRecognition()

    guard let recognizer, recognizer.isAvailable else {
      throw VoiceCommandError.recognitionUnavailable
    }
    guard recognizer.supportsOnDeviceRecognition else {
      throw VoiceCommandError.onDeviceRecognitionUnavailable
    }

    let audioSession = AVAudioSession.sharedInstance()
    try audioSession.setCategory(
      .playAndRecord,
      mode: .voiceChat,
      options: [.allowBluetoothHFP, .defaultToSpeaker, .duckOthers]
    )
    try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

    if let glassesInput = audioSession.availableInputs?.first(where: {
      $0.portType == .bluetoothHFP
    }) {
      try? audioSession.setPreferredInput(glassesInput)
    }

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.requiresOnDeviceRecognition = true
    recognitionRequest = request
    pendingCommand = ""

    let inputNode = audioEngine.inputNode
    let recordingFormat = inputNode.outputFormat(forBus: 0)
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) {
      [weak request] buffer, _ in
      request?.append(buffer)
    }
    inputTapInstalled = true
    audioEngine.prepare()
    try audioEngine.start()

    let sessionID = UUID()
    activeSessionID = sessionID
    recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
      Task { @MainActor in
        guard let self, self.activeSessionID == sessionID else { return }
        if let result {
          self.consumeTranscript(
            result.bestTranscription.formattedString,
            isFinal: result.isFinal
          )
        }
        if error != nil || result?.isFinal == true {
          self.scheduleRecognitionRestart(for: sessionID)
        }
      }
    }
    setState(.listening)
  }

  private func consumeTranscript(_ transcript: String, isFinal: Bool) {
    let lowercased = transcript.lowercased()
    let wakePhrases = ["hey timothy", "hey, timothy"]
    guard let match = wakePhrases.compactMap({ lowercased.range(of: $0) }).first else {
      return
    }

    setState(.hearing)
    let command = String(transcript[match.upperBound...])
      .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    guard command.count >= 2 else { return }

    pendingCommand = command
    commandDebounceTask?.cancel()
    if isFinal {
      submitPendingCommand()
      return
    }

    commandDebounceTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(1.1))
      guard !Task.isCancelled else { return }
      self?.submitPendingCommand()
    }
  }

  private func submitPendingCommand() {
    let command = pendingCommand.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !command.isEmpty else { return }
    pendingCommand = ""
    pauseForResponse()
    onCommand?(command)
  }

  private func scheduleRecognitionRestart(for sessionID: UUID) {
    guard wantsListening, activeSessionID == sessionID, pendingCommand.isEmpty else { return }
    tearDownRecognition()
    Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(350))
      guard let self, self.wantsListening else { return }
      do {
        try self.beginRecognition()
      } catch {
        self.setState(.off)
        self.onError?(error.localizedDescription)
      }
    }
  }

  private func tearDownRecognition() {
    activeSessionID = nil
    commandDebounceTask?.cancel()
    commandDebounceTask = nil
    recognitionTask?.cancel()
    recognitionTask = nil
    recognitionRequest?.endAudio()
    recognitionRequest = nil
    if audioEngine.isRunning {
      audioEngine.stop()
    }
    if inputTapInstalled {
      audioEngine.inputNode.removeTap(onBus: 0)
      inputTapInstalled = false
    }
  }

  private func setState(_ state: VoiceAssistantState) {
    onStateChange?(state)
  }
}
