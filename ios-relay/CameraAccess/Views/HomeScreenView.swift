/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// HomeScreenView.swift
//
// Welcome screen that guides users through the DAT SDK registration process.
// This view is displayed when the app is not yet registered.
//

import MWDATCore
import SwiftUI

struct HomeScreenView: View {
  var viewModel: WearablesViewModel

  var body: some View {
    ZStack {
      HitheTheme.background.edgesIgnoringSafeArea(.all)

      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          HitheWordmark()
            .padding(.bottom, 38)

          Image(systemName: "eyeglasses")
            .font(.system(size: 44, weight: .medium))
            .foregroundStyle(HitheTheme.accent)
            .padding(.bottom, 18)

          Text("Your view, understood.")
            .font(.system(size: 34, weight: .bold))
            .foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)

          Text("Connect your Meta glasses to ask Timothy questions about what is around you.")
            .font(.system(size: 18))
            .foregroundStyle(HitheTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 10)
            .padding(.bottom, 34)

          VStack(spacing: 22) {
            InstructionRow(
              number: 1,
              title: "Connect your glasses",
              detail: "The Meta AI app will open so you can approve access."
            )
            InstructionRow(
              number: 2,
              title: "Start live video",
              detail: "Timothy uses the glasses' point of view, not the iPhone camera."
            )
            InstructionRow(
              number: 3,
              title: "Ask hands-free",
              detail: "Say \"Hey Timothy, what do you see?\""
            )
          }

          HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield.fill")
              .foregroundStyle(HitheTheme.ready)
              .accessibilityHidden(true)
            Text("Timothy sends selected video frames for analysis only after you ask a question.")
              .font(.system(size: 14))
              .foregroundStyle(HitheTheme.secondaryText)
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(.vertical, 24)

          CustomButton(
            title: viewModel.registrationState == .registering ? "Connecting..." : "Connect Meta glasses",
            style: .primary,
            isDisabled: viewModel.registrationState == .registering
          ) {
            viewModel.connectGlasses()
          }
          .accessibilityHint("Opens the Meta AI app to approve the connection")
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 32)
      }
    }
    .preferredColorScheme(.dark)
  }
}
