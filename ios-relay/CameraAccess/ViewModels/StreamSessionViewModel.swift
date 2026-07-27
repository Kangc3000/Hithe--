/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import AVFoundation
import MWDATCamera
import MWDATCore
import Observation
import SwiftUI

enum StreamingStatus {
  case streaming
  case waiting
  case stopped
}

/// ViewModel for video streaming UI. Delegates device management to DeviceSessionManager.
@Observable
@MainActor
final class StreamSessionViewModel {
  // MARK: - State

  var currentVideoFrame: UIImage?
  var hasReceivedFirstFrame: Bool = false
  var streamingStatus: StreamingStatus = .stopped
  var showError: Bool = false
  var errorMessage: String = ""
  var requiresDATAppUpdate: Bool = false

  var capturedPhoto: UIImage?
  var showPhotoPreview: Bool = false
  var showPhotoCaptureError: Bool = false
  var isCapturingPhoto: Bool = false

  var isDescribingScene: Bool = false
  var sceneDescription: String = ""
  var lastQuestion: String = ""
  var voiceAssistantState: VoiceAssistantState = .off
  var speechRoute: TimothySpeechRoute = .phone

  var hasActiveDevice: Bool { sessionManager.hasActiveDevice }
  var isDeviceSessionReady: Bool { sessionManager.isReady }

  var isStreaming: Bool { streamingStatus != .stopped }

  // MARK: - Private

  private let sessionManager: DeviceSessionManager
  private let wearables: WearablesInterface
  private var stream: MWDATCamera.Stream?
  private let sceneDescriptionClient = SceneDescriptionClient()
  private let speechOutputController = SpeechOutputController()
  private let voiceCommandController = VoiceCommandController()
  private var frameBuffer: [BufferedVideoFrame] = []
  private var lastBufferedFrameAt = Date.distantPast
  private var didAutoStartVoiceAssistant = false

  private var stateListenerToken: AnyListenerToken?
  private var videoFrameListenerToken: AnyListenerToken?
  private var errorListenerToken: AnyListenerToken?
  private var photoDataListenerToken: AnyListenerToken?

  // MARK: - Init

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    self.sessionManager = DeviceSessionManager(wearables: wearables)
    voiceCommandController.onStateChange = { [weak self] state in
      self?.voiceAssistantState = state
    }
    voiceCommandController.onCommand = { [weak self] command in
      Task { @MainActor in
        await self?.answerVisualQuestion(command)
      }
    }
    voiceCommandController.onError = { [weak self] message in
      self?.showError(message)
    }
    speechOutputController.onRouteChange = { [weak self] route in
      self?.speechRoute = route
    }
    speechOutputController.onFinished = { [weak self] in
      Task { @MainActor in
        self?.voiceCommandController.resumeAfterResponse()
      }
    }
  }

  // MARK: - Public API

  func handleStartStreaming() async {
    let permission = Permission.camera
    do {
      var status = try await wearables.checkPermissionStatus(permission)
      if status != .granted {
        status = try await wearables.requestPermission(permission)
      }
      guard status == .granted else {
        showError("Permission denied")
        return
      }
      await startSession()
    } catch {
      // Use `localizedDescription` for user-facing text — `description` is
      // always English and intended for logs.
      showError("Permission error: \(error.localizedDescription)")
    }
  }

  func stopSession() {
    voiceCommandController.stop()
    speechOutputController.stop()
    stream?.stop()
  }

  /// Stops both the stream and the underlying device session. Call in test tearDown.
  func endSession() {
    stream = nil
    clearListeners()
    streamingStatus = .stopped
    currentVideoFrame = nil
    hasReceivedFirstFrame = false
    frameBuffer.removeAll()
    didAutoStartVoiceAssistant = false
    voiceCommandController.stop()
    speechOutputController.stop()
    sessionManager.cleanup()
  }

  func capturePhoto() {
    guard !isCapturingPhoto, streamingStatus == .streaming else {
      showPhotoCaptureError = true
      return
    }
    isCapturingPhoto = true
    let success = stream?.capturePhoto(format: .jpeg) ?? false
    if !success {
      isCapturingPhoto = false
      showPhotoCaptureError = true
    }
  }

  func describeScene() async {
    await answerVisualQuestion("Describe what is around me right now.")
  }

  func toggleVoiceAssistant() async {
    if voiceAssistantState == .off {
      await voiceCommandController.start()
    } else {
      voiceCommandController.stop()
    }
  }

  func repeatSceneDescription() {
    guard !sceneDescription.isEmpty else { return }
    let language = UserDefaults.standard.string(
      forKey: SceneDescriptionClient.languageDefaultsKey
    ) ?? "en"
    speak(sceneDescription, language: language, force: true)
  }

  func previewSpeechVoice() {
    let language = UserDefaults.standard.string(
      forKey: SceneDescriptionClient.languageDefaultsKey
    ) ?? "en"
    voiceCommandController.pauseForResponse()
    speak(
      language == "zh" ? "Timothy 已連接，我會透過眼鏡回答。" : "Timothy is connected. I will answer through your glasses.",
      language: language,
      force: true
    )
  }

  func refreshSpeechRoute() {
    speechOutputController.refreshRoute()
  }

  func dismissError() {
    showError = false
    errorMessage = ""
  }

  func dismissPhotoCaptureError() {
    showPhotoCaptureError = false
  }

  func dismissPhotoPreview() {
    showPhotoPreview = false
    capturedPhoto = nil
  }

  // MARK: - Private

  private func startSession() async {
    let deviceSession: DeviceSession
    do {
      deviceSession = try await sessionManager.getSession()
      requiresDATAppUpdate = false
    } catch DeviceSessionError.datAppOnTheGlassesUpdateRequired {
      requiresDATAppUpdate = true
      showError(DeviceSessionError.datAppOnTheGlassesUpdateRequired.localizedDescription)
      return
    } catch {
      showError("Failed to start session: \(error.localizedDescription)")
      return
    }

    guard deviceSession.state == .started else {
      showError("Device session is not ready. Please try again.")
      return
    }

    let config = StreamConfiguration(
      videoCodec: VideoCodec.raw,
      resolution: StreamingResolution.low,
      frameRate: 24
    )

    do {
      guard let newStream = try deviceSession.addStream(config: config) else {
        showError("Unable to create stream. Please try again.")
        return
      }
      stream = newStream
      streamingStatus = .waiting
      setupListeners(for: newStream)
      newStream.start()
    } catch {
      showError("Failed to start stream: \(error.localizedDescription)")
    }
  }

  private func setupListeners(for stream: MWDATCamera.Stream) {
    stateListenerToken = stream.statePublisher.listen { [weak self] state in
      Task { @MainActor in self?.handleStateChange(state) }
    }

    videoFrameListenerToken = stream.videoFramePublisher.listen { [weak self] frame in
      Task { @MainActor in self?.handleVideoFrame(frame) }
    }

    errorListenerToken = stream.errorPublisher.listen { [weak self] error in
      Task { @MainActor in self?.handleError(error) }
    }

    photoDataListenerToken = stream.photoDataPublisher.listen { [weak self] data in
      Task { @MainActor in self?.handlePhotoData(data) }
    }
  }

  private func clearListeners() {
    stateListenerToken = nil
    videoFrameListenerToken = nil
    errorListenerToken = nil
    photoDataListenerToken = nil
  }

  private func handleStateChange(_ state: StreamState) {
    switch state {
    case .stopped:
      currentVideoFrame = nil
      streamingStatus = .stopped
      frameBuffer.removeAll()
      voiceCommandController.stop()
      stream = nil
      clearListeners()
      hasReceivedFirstFrame = false
      sessionManager.stopCurrentSession()
    case .waitingForDevice, .starting, .stopping, .paused:
      streamingStatus = .waiting
    case .streaming:
      streamingStatus = .streaming
      if !didAutoStartVoiceAssistant {
        didAutoStartVoiceAssistant = true
        Task { await voiceCommandController.start() }
      }
    }
  }

  private func handleVideoFrame(_ frame: VideoFrame) {
    if let image = frame.makeUIImage() {
      currentVideoFrame = image
      bufferVideoFrame(image)
      if !hasReceivedFirstFrame {
        hasReceivedFirstFrame = true
      }
    }
  }

  private func handleError(_ error: StreamError) {
    let message = error.localizedDescription
    if message != errorMessage {
      showError(message)
    }
  }

  private func handlePhotoData(_ data: PhotoData) {
    isCapturingPhoto = false
    if let image = UIImage(data: data.data) {
      capturedPhoto = image
      showPhotoPreview = true
    }
  }

  private func speak(_ text: String, language: String, force: Bool = false) {
    guard force || TimothySpeechSettings.automaticallySpeaksAnswers else {
      voiceCommandController.resumeAfterResponse()
      return
    }
    voiceCommandController.markSpeaking()
    speechOutputController.speak(text, language: language)
  }

  private func answerVisualQuestion(_ question: String) async {
    guard !isDescribingScene else { return }
    let jpegFrames = selectedJPEGFrames(for: question)
    guard !jpegFrames.isEmpty else {
      showError("Wait for the glasses video, then ask Timothy again.")
      voiceCommandController.resumeAfterResponse()
      return
    }

    isDescribingScene = true
    lastQuestion = question
    voiceCommandController.pauseForResponse()
    defer { isDescribingScene = false }

    do {
      let result = try await sceneDescriptionClient.answer(
        question: question,
        jpegFrames: jpegFrames
      )
      sceneDescription = result.description
      speak(result.description, language: result.language)
    } catch {
      showError("Timothy: \(error.localizedDescription)")
      voiceCommandController.resumeAfterResponse()
    }
  }

  private func bufferVideoFrame(_ image: UIImage) {
    let now = Date()
    guard now.timeIntervalSince(lastBufferedFrameAt) >= 0.5 else { return }
    lastBufferedFrameAt = now
    frameBuffer.append(BufferedVideoFrame(capturedAt: now, image: image))
    frameBuffer.removeAll { now.timeIntervalSince($0.capturedAt) > 8 }
    if frameBuffer.count > 16 {
      frameBuffer.removeFirst(frameBuffer.count - 16)
    }
  }

  private func selectedJPEGFrames(for question: String) -> [Data] {
    let temporalWords = ["just", "passed", "before", "ago", "moving", "went", "car"]
    let isTemporal = temporalWords.contains { question.localizedCaseInsensitiveContains($0) }
    let candidates = isTemporal ? frameBuffer : Array(frameBuffer.suffix(5))
    let desiredCount = min(isTemporal ? 6 : 3, candidates.count)
    guard desiredCount > 0 else { return [] }
    if desiredCount == 1 {
      return candidates[0].image.jpegData(compressionQuality: 0.68).map { [$0] } ?? []
    }

    var indices: [Int] = []
    for position in 0..<desiredCount {
      let fraction = Double(position) / Double(desiredCount - 1)
      let index = Int((fraction * Double(candidates.count - 1)).rounded())
      if indices.last != index {
        indices.append(index)
      }
    }
    return indices.compactMap {
      candidates[$0].image.jpegData(compressionQuality: 0.68)
    }
  }

  private func showError(_ message: String) {
    errorMessage = message
    showError = true
  }
}

private struct BufferedVideoFrame {
  let capturedAt: Date
  let image: UIImage
}
