import SwiftUI
import ScribeCore

/// The pill: a live level meter while recording, a spinner while transcribing,
/// a checkmark when the text has landed.
struct OverlayView: View {
    @Bindable var model: OverlayModel

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 6) {
                Text(model.state.overlayLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                if model.state == .recording {
                    LevelMeter(level: model.level)
                        .frame(height: 16)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 260, height: 76, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .animation(.easeOut(duration: 0.18), value: model.state)
    }

    @ViewBuilder
    private var icon: some View {
        switch model.state {
        case .recording:
            Image(systemName: "mic.fill")
                .foregroundStyle(.red)
                .font(.system(size: 16))
        case .transcribing, .injecting:
            ProgressView()
                .controlSize(.small)
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 16))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 16))
        case .idle:
            EmptyView()
        }
    }
}

/// Bars driven by the live input level.
///
/// Each bar has a fixed weight so the shape reads as a waveform rather than a
/// row of identical blocks — the level scales it, the weights give it form.
private struct LevelMeter: View {
    let level: Float

    private static let weights: [Float] = [
        0.35, 0.55, 0.8, 1.0, 0.75, 0.95, 0.6, 0.85, 1.0, 0.7, 0.5, 0.8,
        0.6, 0.9, 0.45, 0.7, 0.55, 0.35,
    ]

    var body: some View {
        GeometryReader { geometry in
            let count = Self.weights.count
            let spacing: CGFloat = 2
            let width = max(1, (geometry.size.width - spacing * CGFloat(count - 1))
                            / CGFloat(count))

            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<count, id: \.self) { index in
                    let scaled = CGFloat(level * Self.weights[index])
                    let height = max(2, scaled * geometry.size.height)
                    Capsule()
                        .fill(.tint)
                        .frame(width: width, height: height)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .animation(.linear(duration: 0.06), value: level)
        }
    }
}

// MARK: - Previews

#if DEBUG
/// The overlay takes a model rather than the coordinator, so its states can be
/// previewed directly — this is the view whose whole job is looking right in
/// each one, and the only way to see them in the running app is to talk into it.
@MainActor
private func overlayModel(_ state: DictationState, level: Float = 0) -> OverlayModel {
    let model = OverlayModel()
    model.state = state
    model.level = level
    return model
}

#Preview("Every state") {
    VStack(spacing: 12) {
        OverlayView(model: overlayModel(.recording, level: 0.2))
        OverlayView(model: overlayModel(.recording, level: 0.85))
        OverlayView(model: overlayModel(.transcribing))
        OverlayView(model: overlayModel(.injecting))
        OverlayView(model: overlayModel(.finished("Hello there.")))
        OverlayView(model: overlayModel(.failed("No speech detected.")))
    }
    .padding(24)
    // The panel is transparent and floats over other apps, so a preview on a
    // plain background would flatter it. This is closer to what it sits on.
    .background(LinearGradient(colors: [.indigo, .teal],
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing))
}

/// The failure text comes from real errors, some of which are long. Worth
/// seeing where the pill's fixed width truncates them.
#Preview("Long failure text") {
    VStack(spacing: 12) {
        OverlayView(model: overlayModel(
            .failed("No model installed — open Settings ▸ Model to download one.")))
        OverlayView(model: overlayModel(
            .failed("Another app has secure input enabled, so the text was copied instead.")))
    }
    .padding(24)
    .background(.black)
}

#Preview("Level sweep") {
    VStack(spacing: 8) {
        ForEach([0.0, 0.15, 0.35, 0.6, 0.8, 1.0], id: \.self) { level in
            OverlayView(model: overlayModel(.recording, level: Float(level)))
        }
    }
    .padding(24)
    .background(.black)
}
#endif
