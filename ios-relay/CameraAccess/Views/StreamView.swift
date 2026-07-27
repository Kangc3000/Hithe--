/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import AVFoundation
import MWDATCore
import SwiftUI

struct StreamView: View {
  @Bindable var viewModel: StreamSessionViewModel
  var wearablesVM: WearablesViewModel
  @State private var showSceneSettings = false

  private var voiceTint: Color {
    switch viewModel.voiceAssistantState {
    case .off:
      return HitheTheme.warning
    case .thinking, .speaking:
      return HitheTheme.accent
    case .starting, .listening, .hearing:
      return HitheTheme.ready
    }
  }

  var body: some View {
    ZStack {
      Color.black.edgesIgnoringSafeArea(.all)

      if let videoFrame = viewModel.currentVideoFrame, viewModel.hasReceivedFirstFrame {
        GeometryReader { geometry in
          Image(uiImage: videoFrame)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .edgesIgnoringSafeArea(.all)
      } else {
        VStack(spacing: 14) {
          ProgressView()
            .scaleEffect(1.3)
            .tint(HitheTheme.accent)
          Text("Starting glasses video...")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(HitheTheme.secondaryText)
        }
      }

      VStack(spacing: 12) {
        HStack(spacing: 10) {
          HitheWordmark()
          Spacer()

          HStack(spacing: 7) {
            Circle()
              .fill(viewModel.hasReceivedFirstFrame ? HitheTheme.ready : HitheTheme.warning)
              .frame(width: 8, height: 8)
            Text(viewModel.hasReceivedFirstFrame ? "LIVE" : "STARTING")
              .font(.system(size: 12, weight: .bold))
              .foregroundStyle(.white)
          }
          .accessibilityElement(children: .combine)
          .accessibilityLabel(
            viewModel.hasReceivedFirstFrame ? "Glasses video live" : "Glasses video starting"
          )
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(.black.opacity(0.76))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

        Spacer()

        if !viewModel.sceneDescription.isEmpty {
          AnswerPanel(viewModel: viewModel)
        } else if viewModel.voiceAssistantState == .listening {
          ExamplePrompt()
        }

        HStack(spacing: 12) {
          Image(systemName: viewModel.voiceAssistantState.icon)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(voiceTint)
            .frame(width: 26)
            .accessibilityHidden(true)

          VStack(alignment: .leading, spacing: 2) {
            Text(viewModel.voiceAssistantState.label)
              .font(.system(size: 16, weight: .bold))
              .foregroundStyle(.white)
            Text(voiceDetail)
            .font(.system(size: 13))
            .foregroundStyle(HitheTheme.secondaryText)
            .lineLimit(2)
          }

          Spacer(minLength: 0)
        }
        .padding(14)
        .background(.black.opacity(0.82))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)

        ControlsView(viewModel: viewModel, showSceneSettings: $showSceneSettings)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
    }
    .preferredColorScheme(.dark)
    .onDisappear {
      if viewModel.streamingStatus != .stopped {
        viewModel.stopSession()
      }
    }
    .sheet(isPresented: $viewModel.showPhotoPreview) {
      if let photo = viewModel.capturedPhoto {
        PhotoPreviewView(
          photo: photo,
          onDismiss: { viewModel.dismissPhotoPreview() }
        )
      }
    }
    .sheet(isPresented: $showSceneSettings) {
      SceneSettingsView(viewModel: viewModel)
    }
  }

  private var voiceDetail: String {
    if viewModel.voiceAssistantState == .speaking {
      return "Speaking through \(viewModel.speechRoute.name)."
    }
    if viewModel.voiceAssistantState == .off {
      return "Tap Voice below to turn it on."
    }
    return "Keep the Mac relay Terminal window open."
  }
}

private struct AnswerPanel: View {
  var viewModel: StreamSessionViewModel

  var body: some View {
    Button {
      viewModel.repeatSceneDescription()
    } label: {
      VStack(alignment: .leading, spacing: 8) {
        if !viewModel.lastQuestion.isEmpty {
          Text(viewModel.lastQuestion)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(HitheTheme.accent)
            .lineLimit(2)
        }

        HStack(alignment: .top, spacing: 12) {
          Image(systemName: "speaker.wave.2.fill")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(HitheTheme.accent)
            .accessibilityHidden(true)
          Text(viewModel.sceneDescription)
            .font(.system(size: 19, weight: .semibold))
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .foregroundStyle(.white)
      .padding(16)
      .background(.black.opacity(0.84))
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(
      "Timothy answered: \(viewModel.sceneDescription). Double tap to hear it again."
    )
  }
}

private struct ExamplePrompt: View {
  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "quote.bubble.fill")
        .font(.system(size: 19, weight: .semibold))
        .foregroundStyle(HitheTheme.accent)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        Text("Try saying")
          .font(.system(size: 13, weight: .bold))
          .foregroundStyle(HitheTheme.secondaryText)
        Text("\"Hey Timothy, what do you see?\"")
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(.white)
      }

      Spacer(minLength: 0)
    }
    .padding(14)
    .background(.black.opacity(0.76))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}

struct ControlsView: View {
  var viewModel: StreamSessionViewModel
  @Binding var showSceneSettings: Bool

  var body: some View {
    HStack(spacing: 4) {
      StreamControlButton(
        icon: "stop.fill",
        label: "Stop",
        tint: HitheTheme.danger
      ) {
        viewModel.stopSession()
      }

      StreamControlButton(
        icon: viewModel.isDescribingScene ? "hourglass" : "eye.fill",
        label: "Ask now",
        tint: HitheTheme.accent,
        isDisabled: viewModel.isDescribingScene || !viewModel.hasReceivedFirstFrame
      ) {
        Task { await viewModel.describeScene() }
      }
      .accessibilityLabel(viewModel.isDescribingScene ? "Describing scene" : "Describe scene now")
      .accessibilityIdentifier("describe_scene_button")

      StreamControlButton(
        icon: viewModel.voiceAssistantState == .off ? "mic.slash.fill" : "mic.fill",
        label: "Voice",
        tint: viewModel.voiceAssistantState == .off ? HitheTheme.warning : HitheTheme.ready
      ) {
        Task { await viewModel.toggleVoiceAssistant() }
      }
      .accessibilityLabel(
        viewModel.voiceAssistantState == .off ? "Enable Hey Timothy" : "Disable Hey Timothy"
      )
      .accessibilityIdentifier("voice_assistant_button")

      StreamControlButton(
        icon: "gearshape.fill",
        label: "Settings",
        tint: .white
      ) {
        showSceneSettings = true
      }
      .accessibilityLabel("Timothy settings")
    }
    .frame(height: 72)
    .padding(.horizontal, 4)
    .background(.black.opacity(0.86))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

private struct StreamControlButton: View {
  let icon: String
  let label: String
  let tint: Color
  var isDisabled = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(spacing: 5) {
        Image(systemName: icon)
          .font(.system(size: 19, weight: .bold))
          .frame(height: 22)
        Text(label)
          .font(.system(size: 12, weight: .semibold))
          .lineLimit(1)
      }
      .foregroundStyle(tint)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(isDisabled)
    .opacity(isDisabled ? 0.35 : 1)
  }
}

private struct SceneSettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @Bindable var viewModel: StreamSessionViewModel
  @AppStorage(SceneDescriptionClient.endpointDefaultsKey)
  private var endpoint = SceneDescriptionClient.defaultEndpoint
  @AppStorage(SceneDescriptionClient.languageDefaultsKey)
  private var language = "en"
  @AppStorage(TimothySpeechSettings.voiceIdentifierKey)
  private var voiceIdentifier = TimothySpeechSettings.automaticVoiceIdentifier
  @AppStorage(TimothySpeechSettings.automaticallySpeakKey)
  private var automaticallySpeak = true

  private var voices: [AVSpeechSynthesisVoice] {
    TimothySpeechSettings.installedVoices(language: language)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Mac relay") {
          TextField("Relay address", text: $endpoint)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
          Label(
            "Keep the relay Terminal window open while Timothy is running.",
            systemImage: "desktopcomputer"
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
        }

        Section("Answer language") {
          Picker("Language", selection: $language) {
            Text("English").tag("en")
            Text("Traditional Chinese").tag("zh")
          }
          .pickerStyle(.segmented)
        }

        Section("Spoken answers") {
          Toggle("Speak answers automatically", isOn: $automaticallySpeak)

          Picker("Voice", selection: $voiceIdentifier) {
            Text("Natural voice (recommended)")
              .tag(TimothySpeechSettings.automaticVoiceIdentifier)
            ForEach(voices, id: \.identifier) { voice in
              Text(voice.name).tag(voice.identifier)
            }
          }

          LabeledContent("Audio output") {
            Label(
              viewModel.speechRoute.name,
              systemImage: viewModel.speechRoute.isBluetooth
                ? "eyeglasses" : "iphone.gen3"
            )
            .foregroundStyle(
              viewModel.speechRoute.isBluetooth ? HitheTheme.ready : .secondary
            )
          }

          Button {
            viewModel.previewSpeechVoice()
          } label: {
            Label("Test voice", systemImage: "speaker.wave.2.fill")
          }

          Text("For glasses audio, keep Ray-Ban Meta selected as the iPhone's Bluetooth audio device.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
      .navigationTitle("Timothy Settings")
      .onAppear {
        viewModel.refreshSpeechRoute()
      }
      .onChange(of: language) {
        voiceIdentifier = TimothySpeechSettings.automaticVoiceIdentifier
      }
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
  }
}
