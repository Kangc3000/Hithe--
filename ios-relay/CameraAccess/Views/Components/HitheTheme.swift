import SwiftUI

enum HitheTheme {
  static let background = Color(red: 0.035, green: 0.045, blue: 0.055)
  static let surface = Color(red: 0.09, green: 0.11, blue: 0.13)
  static let surfaceStrong = Color(red: 0.13, green: 0.15, blue: 0.17)
  static let accent = Color(red: 0.22, green: 0.82, blue: 0.84)
  static let ready = Color(red: 0.31, green: 0.82, blue: 0.52)
  static let warning = Color(red: 1.0, green: 0.72, blue: 0.24)
  static let danger = Color(red: 1.0, green: 0.36, blue: 0.38)
  static let secondaryText = Color.white.opacity(0.72)
}

struct HitheWordmark: View {
  var body: some View {
    HStack(spacing: 9) {
      Image(systemName: "waveform.and.mic")
        .font(.system(size: 18, weight: .bold))
        .foregroundStyle(HitheTheme.accent)

      Text("TIMOTHY")
        .font(.system(size: 15, weight: .bold))
        .foregroundStyle(.white)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Timothy by Hithe")
  }
}

struct InstructionRow: View {
  let number: Int
  let title: String
  let detail: String

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      Text("\(number)")
        .font(.system(size: 15, weight: .bold))
        .foregroundStyle(HitheTheme.background)
        .frame(width: 30, height: 30)
        .background(HitheTheme.accent)
        .clipShape(Circle())
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(.white)

        Text(detail)
          .font(.system(size: 15))
          .foregroundStyle(HitheTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
  }
}

struct ReadinessRow: View {
  let icon: String
  let title: String
  let detail: String
  let tint: Color

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: icon)
        .font(.system(size: 20, weight: .semibold))
        .foregroundStyle(tint)
        .frame(width: 30, height: 30)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(.white)

        Text(detail)
          .font(.system(size: 14))
          .foregroundStyle(HitheTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
  }
}
