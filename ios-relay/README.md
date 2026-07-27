# Hithe iOS relay

Native SwiftUI starting point for the iPhone version of Hithe. It is based on
Meta's official CameraAccess sample and uses Meta Wearables Device Access
Toolkit 0.8.0 through Swift Package Manager.

The app verifies the complete iPhone-to-Meta-AI registration and glasses camera
streaming path. While streaming, say "Hey Timothy" followed by a question. The
app selects recent frames, sends them to the local Mac scene relay, displays the
answer, and reads it aloud through the active Bluetooth audio route. Tap the
answer to hear it again, or use the eye button to request an immediate scene
description.

## Run

1. Open `CameraAccess.xcodeproj` in Xcode.
2. Select the `CameraAccess` target and your personal development team.
3. Select the connected iPhone and press Run.
4. In Meta AI, enable Developer Mode for the connected glasses.
5. Start `../openclaw-skills/scene-describe/scene_server.py` on the Mac with an
   `OPENAI_API_KEY` in its environment.

The gear button beside the stream controls changes the Mac relay address,
selects English or Traditional Chinese, chooses an installed iPhone voice, and
tests the current audio output. The default relay address is
`http://Kangs-iMac.local:8787/describe`.

Meta's DAT SDK exposes the glasses as Bluetooth microphone and speaker hardware;
it does not expose the proprietary Meta AI narrator voice. Timothy therefore
uses the best installed iOS system voice by default and explicitly prefers the
glasses' Bluetooth HFP route. The iPhone app contains no OpenAI credential, and
the Mac relay does not save image or description data.

The app's bundle identifier is `com.kangc3000.hithe`, its callback scheme is
`hithe://`, and Meta development registration uses app ID `0`.

## Upstream attribution

The initial project and camera integration are derived from Meta's
`meta-wearables-dat-ios` CameraAccess sample and remain subject to the license
and notice files in that upstream repository.
