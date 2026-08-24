#if DEBUG
import SwiftUI
import ClioCore

/// A stand-in desktop for the previews.
///
/// Glass shows nothing against a flat colour — it samples what is behind it,
/// so a preview on a plain background flatters every setting equally and
/// decides nothing. This gives it something to sample: bright and dark areas,
/// a hard edge between them, and small shapes that either read through the
/// pill or do not.
private struct Backdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.42, green: 0.55, blue: 0.20),
                                    Color(red: 0.85, green: 0.66, blue: 0.13)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            // A window edge — the case that showed the pill banding in two.
            VStack(spacing: 0) {
                Color.clear.frame(height: 54)
                Color(red: 0.16, green: 0.20, blue: 0.34)
            }
            HStack(spacing: 26) {
                RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.85))
                    .frame(width: 42, height: 42)
                Circle().fill(.white.opacity(0.9)).frame(width: 30, height: 30)
                RoundedRectangle(cornerRadius: 8).fill(Color.blue)
                    .frame(width: 46, height: 30)
            }
            .offset(x: -60, y: 22)
        }
    }
}

@MainActor
private func pill(_ surface: PillSurface, state: DictationState = .transcribing) -> OverlayModel {
    let model = OverlayModel()
    model.state = state
    model.level = 0.7
    model.surface = surface
    return model
}

private struct SurfaceRow: View {
    let preset: PillSurface.Preset

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name).font(.headline)
                Text(preset.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(preset.surface.isClear
                     ? "clear · \(Int(preset.surface.opacity * 100))%"
                     : "frosted · \(Int(preset.surface.opacity * 100))%")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 190, alignment: .leading)

            ZStack {
                Backdrop()
                OverlayView(model: pill(preset.surface))
            }
            .frame(width: 330, height: 110)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// The five surfaces, side by side over the same backdrop.
///
/// Pick one and it becomes the default; the numbers under each name are what
/// the Translucency slider would read.
#Preview("Pill surfaces — light") {
    VStack(alignment: .leading, spacing: 10) {
        ForEach(PillSurface.presets, id: \.name) { SurfaceRow(preset: $0) }
    }
    .padding(20)
    .environment(\.colorScheme, .light)
}

#Preview("Pill surfaces — dark") {
    VStack(alignment: .leading, spacing: 10) {
        ForEach(PillSurface.presets, id: \.name) { SurfaceRow(preset: $0) }
    }
    .padding(20)
    .environment(\.colorScheme, .dark)
}

/// The same five while recording, where the pill is narrow and the level bars
/// have to hold up rather than a solid run of text.
#Preview("Pill surfaces — recording") {
    VStack(alignment: .leading, spacing: 10) {
        ForEach(PillSurface.presets, id: \.name) { preset in
            HStack(spacing: 0) {
                Text(preset.name).font(.headline)
                    .frame(width: 110, alignment: .leading)
                ZStack {
                    Backdrop()
                    OverlayView(model: pill(preset.surface, state: .recording))
                }
                .frame(width: 300, height: 105)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }
    .padding(20)
}
#endif
