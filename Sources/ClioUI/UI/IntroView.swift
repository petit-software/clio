import SwiftUI
import ClioCore

/// Which face of the intro card is showing.
public enum IntroStep: Sendable {
    /// What Clio is, in one breath, and a Get Started button.
    case welcome
    /// The two permissions and the first model. Replaces the old onboarding
    /// window (§7): same asks, on the same card as the welcome.
    case setup
}

/// The first thing a new user sees: a welcome, then setup, on one card.
///
/// Draws its own surface with 32pt corners. The window it lives in is
/// borderless and transparent (`IntroWindowController`), so the rounded card
/// IS the window: the corners are real, the shadow follows them, and there is
/// no title bar to argue with the artwork. Both steps share the one card, so
/// moving between them changes nothing about the window.
struct IntroView: View {
    @Bindable var coordinator: AppCoordinator
    let dismiss: () -> Void

    @State private var step: IntroStep
    @State private var hasEntered = false

    init(coordinator: AppCoordinator,
         startingAt step: IntroStep = .welcome,
         dismiss: @escaping () -> Void) {
        self.coordinator = coordinator
        self.dismiss = dismiss
        _step = State(initialValue: step)
    }

    static let cornerRadius: CGFloat = 32
    static let size = CGSize(width: 420, height: 480)

    /// How the card arrives: a fade with a little growth, 0.92 → 1. Each
    /// element on it then does the same, one step behind the last, so the
    /// card settles first and its contents follow it in. A step change plays
    /// the same entrance for the new step's elements.
    ///
    /// Animated on the view rather than the window. The window is transparent
    /// and already the card's final size, so scaling the content inside it
    /// costs nothing and never touches the frame; a window that changes size
    /// while it fades is what stale shadows are made of.
    static let entrance: Animation = .easeOut(duration: 0.3)
    static let entranceScale: CGFloat = 0.92
    /// Gap between one element starting and the next.
    static let entranceStep: TimeInterval = 0.07

    var body: some View {
        ZStack {
            switch step {
            case .welcome:
                WelcomeStep {
                    withAnimation(Self.entrance) { step = .setup }
                }
                .transition(.leaving)
            case .setup:
                SetupStep(coordinator: coordinator, dismiss: dismiss)
                    .transition(.leaving)
            }
        }
        .padding(.horizontal, 25)
        .padding(.vertical, 36)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(shape)
        // A hairline at the edge so the card still has one against a
        // background the same colour as itself. Overlaid, not stroked on
        // the clip, so it sits half inside and is not shaved off.
        .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
        .entering(hasEntered, step: 0)
        // A plain assignment, not `withAnimation`: each element carries its
        // own delayed copy of the animation, and one animation wrapped around
        // the change would apply to all of them at once.
        .onAppear { hasEntered = true }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
    }
}

// MARK: - Welcome

private struct WelcomeStep: View {
    let getStarted: () -> Void
    @State private var hasEntered = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            AppIcon.image
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
                .accessibilityHidden(true)
                .entering(hasEntered, step: 1)

            VStack(spacing: 10) {
                Text("Welcome to Clio")
                    .font(.system(size: 26, weight: .bold))
                    .entering(hasEntered, step: 2)
                // Two sentences, one per line: each fits the card's width on
                // its own, and the break keeps them from re-wrapping into
                // three uneven lines.
                Text("Turn your voice into polished text.\n"
                     + "Works in Slack, Gmail and any other site or app.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .entering(hasEntered, step: 3)
            }
            .padding(.top, 24)

            Spacer(minLength: 0)

            Button("Get Started", action: getStarted)
                .buttonStyle(IntroButtonStyle())
                .keyboardShortcut(.defaultAction)
                .entering(hasEntered, step: 4)
        }
        .onAppear { hasEntered = true }
    }
}

// MARK: - Setup

/// Microphone first because it prompts inline; Accessibility second because
/// it cannot be granted programmatically — the user has to visit System
/// Settings, and the only honest thing to do is deep-link there and wait.
/// The model third, because it is the one that takes a while, and the
/// download keeps going if the card is dismissed. The shortcut last: it has
/// a default, so it is the one row that is already done, and it is what the
/// user reaches for the moment the card closes.
private struct SetupStep: View {
    @Bindable var coordinator: AppCoordinator
    let dismiss: () -> Void
    @State private var hasEntered = false

    /// The model offered here. Small enough to arrive while the user is still
    /// reading, multilingual, and enough to prove the loop works; Settings ▸
    /// Model has the rest.
    static let modelID = "openai_whisper-small_216MB"

    var body: some View {
        VStack(spacing: 0) {
            Text("Set up Clio")
                .font(.system(size: 26, weight: .bold))
                .entering(hasEntered, step: 1)

            VStack(alignment: .leading, spacing: 16) {
                microphoneRow.entering(hasEntered, step: 2)
                accessibilityRow.entering(hasEntered, step: 3)
                modelRow.entering(hasEntered, step: 4)
                shortcutRow.entering(hasEntered, step: 5)
            }
            .padding(.top, 28)

            Spacer(minLength: 16)

            // Grey while there is still something to do: skipping is allowed,
            // but it should not look like the thing to press.
            Button(allDone ? "Start Dictating" : "Skip for now", action: dismiss)
                .buttonStyle(IntroButtonStyle(prominence: allDone ? .primary : .secondary))
                .keyboardShortcut(.defaultAction)
                .entering(hasEntered, step: 6)
        }
        .onAppear {
            hasEntered = true
            permissions.beginPolling()
            models.refreshInstalled()
        }
    }

    private var permissions: PermissionsCoordinator { coordinator.permissions }
    private var models: ModelManager { coordinator.models }

    private var allDone: Bool { permissions.allGranted && modelInstalled }

    // MARK: Rows

    private var microphoneRow: some View {
        SetupRow(number: 1,
                 title: "Microphone",
                 detail: "So Clio can hear you.",
                 done: permissions.microphone.isGranted) {
            // Once macOS has recorded a denial it ignores the API request, so
            // a denied state goes straight to System Settings.
            if permissions.microphone == .notDetermined {
                Button("Allow") { Task { await permissions.requestMicrophone() } }
            } else {
                Button("Open Settings", action: permissions.openMicrophoneSettings)
            }
        }
    }

    private var accessibilityRow: some View {
        SetupRow(number: 2,
                 title: "Accessibility",
                 detail: "Lets Clio paste for you.",
                 done: permissions.accessibility.isGranted) {
            Button("Open Settings") {
                permissions.accessibility == .notDetermined
                    ? permissions.requestAccessibility()
                    : permissions.openAccessibilitySettings()
            }
        }
    }

    private var modelRow: some View {
        SetupRow(number: 3,
                 title: modelTitle,
                 detail: modelDetail,
                 done: modelInstalled,
                 progress: model.flatMap { models.downloads[$0.id] },
                 failure: model.flatMap { models.failures[$0.id] }) {
            // A glyph rather than a capsule: this row's action is the one that
            // turns into a progress bar, and a word-button beside a bar reads
            // as two things where the arrow reads as one.
            if let model {
                if models.isDownloading(model.id) {
                    iconButton("minus.circle.fill", "Cancel the download", .secondary) {
                        models.cancel(model.id)
                    }
                } else {
                    iconButton("arrow.down.circle.fill",
                               models.failures[model.id] == nil
                                   ? "Download \(model.displayName)"
                                   : "Try the download again",
                               .primary) {
                        models.download(model)
                    }
                }
            }
        }
    }

    private func iconButton(_ symbol: String,
                            _ description: String,
                            _ tint: Color,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 24))
                .foregroundStyle(tint)
                // Sized to the compact capsule beside it, so the rows' right
                // edges line up.
                .frame(height: 31)
        }
        .buttonStyle(.borderless)
        .help(description)
        .accessibilityLabel(description)
    }

    private var shortcutRow: some View {
        SetupRow(number: 4,
                 title: "Shortcut",
                 detail: shortcutDetail,
                 done: true,
                 keepsAction: true,
                 placement: .below) {
            HotkeyRecorder(
                style: .intro,
                coordinator: coordinator,
                hotkey: Binding(
                    get: { coordinator.settingsStore.settings.hotkey },
                    set: { coordinator.settingsStore.settings.hotkey = $0 ?? .defaultHotkey }),
                other: coordinator.settingsStore.settings.secondaryHotkey,
                fallback: .defaultHotkey)
        }
    }

    private var shortcutDetail: String {
        let mode = coordinator.settingsStore.settings.hotkeyMode
        return (mode == .pushToTalk ? "Hold to dictate." : "Press to dictate.")
             + " Click to change."
    }

    // MARK: Model

    private var model: CatalogModel? {
        models.catalog.first { $0.id == Self.modelID }
    }

    /// Any installed model counts. Someone reopening setup with Distil Large
    /// already on disk should not be told to download a smaller one.
    private var modelInstalled: Bool { coordinator.activeModel != nil }

    private var modelTitle: String {
        if let active = coordinator.activeModel { return active.displayName }
        return model?.displayName ?? "Speech model"
    }

    private var modelDetail: String {
        if modelInstalled { return "Installed and ready." }
        guard let model else { return "Runs on this Mac." }
        return "\(Self.format(model.approximateBytes)), runs on this Mac."
    }

    static func format(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

/// One thing to do: a numbered badge that becomes a tick, what it is and
/// why, and the one button that moves it along. The button disappears once
/// the row is done; the tick says it all. `keepsAction` is the exception.
private struct SetupRow<Action: View>: View {
    let number: Int
    let title: String
    let detail: String
    let done: Bool
    /// The shortcut row: done from the start, because it has a default, but
    /// the button stays so the default can be changed.
    var keepsAction = false
    /// Where the action sits. Trailing is the norm; the shortcut recorder
    /// goes under its text, because the chord it shows can be three keys
    /// wide and would push the description into a corner.
    var placement: Placement = .trailing
    var progress: DownloadProgress? = nil

    enum Placement { case trailing, below }
    var failure: String? = nil
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(done ? Color.green : Color.secondary.opacity(0.15))
                    .frame(width: 24, height: 24)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(number)")
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .animation(.easeOut(duration: 0.2), value: done)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                // While a download runs the bar IS the description: the size
                // it quoted is now the denominator underneath the bar.
                if let progress {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: progress.fraction)
                            .padding(.top, 4)
                        Text(progressLabel(progress))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                } else {
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let failure {
                    Text(failure)
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if showsAction, placement == .below {
                    action()
                        .buttonStyle(IntroButtonStyle(size: .compact, prominence: .secondary))
                        .padding(.top, 6)
                }
            }

            Spacer(minLength: 8)

            if showsAction, placement == .trailing {
                action()
                    .buttonStyle(IntroButtonStyle(size: .compact))
            }
        }
    }

    private var showsAction: Bool { !done || keepsAction }

    private func progressLabel(_ progress: DownloadProgress) -> String {
        guard progress.totalBytes > 0 else { return "Starting…" }
        let percent = Int((progress.fraction * 100).rounded(.down))
        return "\(percent)% · \(SetupStep.format(progress.receivedBytes)) of "
             + "\(SetupStep.format(progress.totalBytes))"
    }
}

// MARK: - Shared

/// The intro's buttons: a capsule sized to its label, in the appearance's own
/// ink — black on light, white on dark — with the label in the opposite.
/// Always the strongest thing on the card without taking a colour of its own.
///
/// Its own style because `.borderedProminent` fixes the height from the
/// control size — the largest is 28pt tall — and padding added to its label
/// is ignored. This one is what the label's padding says it is.
struct IntroButtonStyle: ButtonStyle {
    enum Size {
        /// The card's one main button: 15pt above and below, 17pt either side.
        case regular
        /// A row's button, beside two lines of text.
        case compact
    }

    enum Prominence {
        /// Ink: black on light, white on dark.
        case primary
        /// A quiet grey, for the way out.
        case secondary
    }

    var size: Size = .regular
    var prominence: Prominence = .primary

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    private var fill: Color {
        switch prominence {
        case .primary: return colorScheme == .dark ? .white : .black
        case .secondary: return .secondary.opacity(0.15)
        }
    }

    private var ink: Color {
        switch prominence {
        case .primary: return colorScheme == .dark ? .black : .white
        case .secondary: return .primary
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        let shape = Capsule()
        configuration.label
            .font(.system(size: size == .regular ? 15 : 13, weight: .semibold))
            .foregroundStyle(ink)
            .padding(.vertical, size == .regular ? 15 : 7)
            .padding(.horizontal, size == .regular ? 17 : 12)
            .background(shape.fill(fill))
            // Dimmed rather than brightened when pressed: there is nowhere
            // brighter than white, or darker than black, to go.
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.5)
            .contentShape(shape)
    }
}

private extension View {
    /// The intro's entrance, applied to one element: hidden and slightly
    /// small until `entered`, then the shared fade-and-grow, `step` steps
    /// behind the card.
    func entering(_ entered: Bool, step: Int) -> some View {
        scaleEffect(entered ? 1 : IntroView.entranceScale)
            .opacity(entered ? 1 : 0)
            .animation(IntroView.entrance.delay(Double(step) * IntroView.entranceStep),
                       value: entered)
    }
}

private extension AnyTransition {
    /// A step on its way out: the entrance, reversed. On the way in it does
    /// nothing, because the new step's elements stage their own entrance.
    static var leaving: AnyTransition {
        .asymmetric(
            insertion: .identity,
            removal: .opacity.combined(with: .scale(scale: IntroView.entranceScale)))
    }
}

// MARK: - Previews

#if DEBUG
/// Padded on a contrasting ground so the corners and the hairline can be seen;
/// in the app the same card sits alone in a transparent window.
///
/// Setup is the one step that must be previewable in states this Mac is not
/// in — it only ever appears when something is missing, and by the time you
/// are developing, everything is granted.
private func onGround<Content: View>(_ content: Content) -> some View {
    content
        .padding(40)
        .background(Color(nsColor: .underPageBackgroundColor))
}

#Preview("Welcome") {
    onGround(IntroView(coordinator: Preview.coordinator()) {})
}

#Preview("Welcome — dark") {
    onGround(IntroView(coordinator: Preview.coordinator()) {})
        .preferredColorScheme(.dark)
}

#Preview("Setup — nothing granted") {
    onGround(IntroView(
        coordinator: Preview.coordinator(
            microphone: .notDetermined, accessibility: .notDetermined, installed: []),
        startingAt: .setup) {})
}

#Preview("Setup — downloading") {
    onGround(IntroView(coordinator: Preview.freshCoordinator, startingAt: .setup) {})
}

/// Denied is not the same as not-yet-asked: macOS ignores the API request once
/// it has recorded a denial, so these rows must offer System Settings instead.
#Preview("Setup — denied, download failed") {
    onGround(IntroView(
        coordinator: Preview.coordinator(
            microphone: .denied, accessibility: .denied, installed: [],
            failures: [SetupStep.modelID: "The network connection was lost."]),
        startingAt: .setup) {})
}

#Preview("Setup — all set") {
    onGround(IntroView(coordinator: Preview.coordinator(), startingAt: .setup) {})
}

#Preview("Setup — dark") {
    onGround(IntroView(
        coordinator: Preview.coordinator(microphone: .granted, accessibility: .notDetermined,
                                         installed: []),
        startingAt: .setup) {})
        .preferredColorScheme(.dark)
}
#endif
