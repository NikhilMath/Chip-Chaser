import SwiftUI

/// A poker chip: orange with a check when collected, a grey empty slot when missing.
struct ChipIcon: View {
    var collected: Bool
    var size: CGFloat = 36

    var body: some View {
        let rim = size * 0.16
        let stripeRadius = (size - rim) / 2
        let segment = (2 * .pi * stripeRadius) / 16

        ZStack {
            Circle()
                .fill(collected ? Color.accentColor : Color(.secondarySystemFill))
            Circle()
                .strokeBorder(
                    collected ? Color.white.opacity(0.92) : Color(.tertiaryLabel),
                    style: StrokeStyle(lineWidth: rim, dash: [segment, segment], dashPhase: segment / 2)
                )
            Circle()
                .fill(collected ? Color.black.opacity(0.88) : Color(.systemBackground))
                .padding(size * 0.25)
            if collected {
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.26, weight: .heavy))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

#Preview {
    HStack(spacing: 24) {
        ChipIcon(collected: true, size: 96)
        ChipIcon(collected: false, size: 96)
        ChipIcon(collected: true)
        ChipIcon(collected: false)
    }
    .padding()
}
