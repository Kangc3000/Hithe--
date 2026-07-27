/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// NonStreamView.swift
//
// Default screen to show getting started tips after app connection
// Initiates streaming
//

import MWDATCore
import SwiftUI

private let updateRequiredBackgroundColor = Color(red: 1.0, green: 0.957, blue: 0.839)
private let updateRequiredForegroundColor = Color(red: 0.541, green: 0.294, blue: 0.0)
private let updateRequiredTitle = "Update required"

struct NonStreamView: View {
  var viewModel: StreamSessionViewModel
  @Bindable var wearablesVM: WearablesViewModel
  @State private var sheetHeight: CGFloat = 520

  private var isUpdateRequired: Bool {
    wearablesVM.requiresFirmwareUpdate || viewModel.requiresDATAppUpdate
  }

  var body: some View {
    ZStack {
      HitheTheme.background.edgesIgnoringSafeArea(.all)

      VStack(spacing: 0) {
        HStack {
          HitheWordmark()
          Spacer()
          Menu {
            Button("Disconnect glasses", role: .destructive) {
              wearablesVM.disconnectGlasses()
            }
            .disabled(wearablesVM.registrationState != .registered)
          } label: {
            Image(systemName: "gearshape.fill")
              .font(.system(size: 20, weight: .semibold))
              .foregroundStyle(.white)
              .frame(width: 44, height: 44)
              .contentShape(Rectangle())
          }
          .accessibilityLabel("Glasses settings")
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)

        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
              Image(systemName: viewModel.hasActiveDevice ? "eyeglasses" : "eyeglasses.slash")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(viewModel.hasActiveDevice ? HitheTheme.ready : HitheTheme.warning)
                .accessibilityHidden(true)

              VStack(alignment: .leading, spacing: 3) {
                Text(viewModel.hasActiveDevice ? "Glasses ready" : "Finding your glasses")
                  .font(.system(size: 24, weight: .bold))
                  .foregroundStyle(.white)
                Text(viewModel.hasActiveDevice ? "You are ready to start Timothy." : "Keep your glasses nearby, unfolded, and connected in Meta AI.")
                  .font(.system(size: 15))
                  .foregroundStyle(HitheTheme.secondaryText)
                  .fixedSize(horizontal: false, vertical: true)
              }
            }
            .padding(.top, 30)
            .padding(.bottom, 32)

            Text("Before you start")
              .font(.system(size: 15, weight: .bold))
              .foregroundStyle(HitheTheme.secondaryText)
              .textCase(.uppercase)
              .padding(.bottom, 18)

            VStack(spacing: 20) {
              ReadinessRow(
                icon: "eyeglasses",
                title: "Wear and unfold your glasses",
                detail: "The white capture light will show when live video begins.",
                tint: HitheTheme.accent
              )
              ReadinessRow(
                icon: "desktopcomputer",
                title: "Keep the Mac relay running",
                detail: "Leave its Terminal window open while using Timothy.",
                tint: HitheTheme.warning
              )
              ReadinessRow(
                icon: "mic.fill",
                title: "Allow voice access",
                detail: "The first time, choose Allow for microphone and speech recognition.",
                tint: HitheTheme.ready
              )
            }

            if isUpdateRequired {
              UpdateRequiredMessage(
                showFirmwareUpdate: wearablesVM.requiresFirmwareUpdate,
                showDATAppUpdate: viewModel.requiresDATAppUpdate
              )
              .padding(.top, 26)
            }

            if wearablesVM.requiresFirmwareUpdate {
              CustomButton(
                title: "Update glasses firmware",
                style: .primary,
                isDisabled: false
              ) {
                Task { await wearablesVM.openFirmwareUpdate() }
              }
              .padding(.top, 12)
            }

            if viewModel.requiresDATAppUpdate {
              CustomButton(
                title: "Update app on glasses",
                style: .primary,
                isDisabled: false
              ) {
                Task { await wearablesVM.openDATGlassesAppUpdate() }
              }
              .padding(.top, 12)
            }
          }
          .padding(.horizontal, 24)
          .padding(.bottom, 20)
        }

        VStack(spacing: 10) {
          if !viewModel.hasActiveDevice {
            HStack(spacing: 8) {
              ProgressView()
                .tint(HitheTheme.warning)
              Text("Waiting for an active device")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(HitheTheme.secondaryText)
            }
          }

          CustomButton(
            title: "Start live video",
            style: .primary,
            isDisabled: !viewModel.hasActiveDevice || isUpdateRequired
          ) {
            Task { await viewModel.handleStartStreaming() }
          }
          .accessibilityHint("Starts video from the glasses and enables Hey Timothy")
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(HitheTheme.background)
      }
    }
    .preferredColorScheme(.dark)
    .sheet(isPresented: $wearablesVM.showGettingStartedSheet) {
      GettingStartedSheetView(height: $sheetHeight)
        .presentationDetents([.height(sheetHeight)])
        .presentationDragIndicator(.visible)
    }
  }
}

struct UpdateRequiredMessage: View {
  let showFirmwareUpdate: Bool
  let showDATAppUpdate: Bool

  private var message: String {
    if showFirmwareUpdate && showDATAppUpdate {
      return "Your glasses firmware and app need updates before Timothy can start."
    }
    if showFirmwareUpdate {
      return "Your glasses firmware needs an update before Timothy can start."
    }
    return "The app on your glasses needs an update before Timothy can start."
  }

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "exclamationmark.triangle.fill")
        .resizable()
        .aspectRatio(contentMode: .fit)
        .foregroundStyle(updateRequiredForegroundColor)
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 4) {
        Text(updateRequiredTitle)
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(updateRequiredForegroundColor)

        Text(message)
          .font(.system(size: 15))
          .foregroundStyle(updateRequiredForegroundColor)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 0)
    }
    .padding(.all, 16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(updateRequiredBackgroundColor)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

struct GettingStartedSheetView: View {
  @Environment(\.dismiss) var dismiss
  @Binding var height: CGFloat

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Set up Timothy")
          .font(.system(size: 24, weight: .bold))
          .foregroundStyle(.primary)
        Text("Three permissions make the hands-free experience work.")
          .font(.system(size: 15))
          .foregroundStyle(.secondary)
      }

      VStack(spacing: 18) {
        TipItemView(
          icon: "video.fill",
          title: "Glasses video",
          text: "Choose Allow so Timothy can see the live view from your glasses."
        )
        TipItemView(
          icon: "mic.fill",
          title: "Microphone",
          text: "Choose Allow so you can say \"Hey Timothy\" and ask a question."
        )
        TipItemView(
          icon: "text.bubble.fill",
          title: "Speech recognition",
          text: "Choose Allow so your iPhone can understand the spoken command."
        )
        TipItemView(
          icon: "light.beacon.max.fill",
          title: "Capture light",
          text: "The glasses' white light tells people nearby when video is live."
        )
      }

      CustomButton(
        title: "Continue to Timothy",
        style: .primary,
        isDisabled: false
      ) {
        dismiss()
      }
    }
    .padding(.all, 24)
    .background(
      GeometryReader { geo -> Color in
        DispatchQueue.main.async {
          height = geo.size.height
        }
        return Color.clear
      }
    )
  }
}

struct TipItemView: View {
  let icon: String
  let title: String
  let text: String

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: icon)
        .font(.system(size: 20, weight: .semibold))
        .foregroundStyle(Color.accentColor)
        .frame(width: 30)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(.primary)
        Text(text)
          .font(.system(size: 15))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
