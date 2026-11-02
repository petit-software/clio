import SwiftUI
import ClioCore

/// Which face of the intro card is showing.
public enum IntroStep: Sendable {
    /// What Clio is, in one breath, and a Get Started button.
    case welcome
    /// The two permissions, the speech model and the shortcut, as one
    /// checklist with one button that always does the next thing.
    case setup
}

/// The first thing a new user sees: a welcome, then setup, on one card.
///
/// The card is Fino's Access popup in Clio's words — the same glass sheet,
/// type, checklist and single full-width button — so the two apps start the
/// same way. Its materials are in `IntroSurface.swift`.
///
/// Draws its own surface. The window it lives in is borderless and
/// transparent (`IntroWindowController`), so the rounded card IS the window:
/// the corners are real, the shadow follows them, and there is no title bar
/// to argue with the artwork. Both steps share the one card, so moving
/// between them changes nothing about the window.
struct IntroView: View {
    @Bindable var coordinator: AppCoordinator
    let dismiss: () -> Void
    /// Whether the setup step starts the speech model downloading as soon as
    /// it appears. Off in previews, whose model managers are simulated.
    let startsDownload: Bool

    @State private var step: IntroStep
    @State private var hasEntered = false
    @FocusState private var focus: IntroFocus?
    @Environment(\.colorScheme) private var colorScheme

    init(coordinator: AppCoordinator,
         startingAt step: IntroStep = .welcome,
         startsDownload: Bool = true,
         dismiss: @escaping () -> Void) {
        self.coordinator = coordinator
        self.dismiss = dismiss
        self.startsDownload = startsDownload
        _step = State(initialValue: step)
    }

    static let cornerRadius: CGFloat = 32
    static let cardSize = CGSize(width: 420, height: 480)
    /// The window: the card and a point either side of it, where the hairline
    /// outside the card's edge is drawn.
    static let size = CGSize(width: cardSize.width + 2, height: cardSize.height + 2)

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
                WelcomeStep(palette: palette, focus: $focus) {
                    withAnimation(Self.entrance) { step = .setup }
                }
                .transition(.leaving)
            case .setup:
                SetupStep(coordinator: coordinator,
                          palette: palette,
                          focus: $focus,
                          startsDownload: startsDownload,
                          dismiss: dismiss)
                    .transition(.leaving)
            }
        }
        .padding(16)
        .frame(width: Self.cardSize.width, height: Self.cardSize.height)
        .background(IntroSurface(palette: palette))
        .overlay(alignment: .topLeading) {
            IntroCloseButton(palette: palette, focus: $focus, action: dismiss)
                .padding(12)
        }
        .padding(1)
        .entering(hasEntered, step: 0)
        // A plain assignment, not `withAnimation`: each element carries its
        // own delayed copy of the animation, and one animation wrapped around
        // the change would apply to all of them at once.
        .onAppear { hasEntered = true }
        // The main button, not the ✕ that comes first in the view tree, is
        // what has focus when a step appears. A beat late: on the first
        // appearance the window is not key yet, and on a step change the
        // new button is not in the tree until the transition has begun.
        .task(id: step) {
            try? await Task.sleep(for: .milliseconds(60))
            focus = .main
        }
    }

    private var palette: IntroPalette {
        IntroPalette(colorScheme: colorScheme)
    }
}

// MARK: - Welcome

private struct WelcomeStep: View {
    let palette: IntroPalette
    var focus: FocusState<IntroFocus?>.Binding
    let getStarted: () -> Void
    @State private var hasEntered = false

    /// The pill that takes the icon's place, running a dictation that never
    /// happened.
    ///
    /// The real `OverlayView` on a model of its own, so what the card shows
    /// is what the user is about to see — same capsule, same meter, same
    /// labels — rather than a drawing of it.
    @State private var pill = OverlayModel()
    /// Whether the icon is the one on stage. Never true while the pill is
    /// shown: the two take turns in the same spot, they do not share it.
    @State private var iconIsOnStage = true

    var body: some View {
        VStack(spacing: 0) {
            // The stage: the icon, or the pill, given the room. The words
            // wait below, next to the button.
            Spacer(minLength: 0)

            ZStack {
                AppIcon.image
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 96, height: 96)
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
                    // Goes and comes the way everything on the card does.
                    .scaleEffect(iconIsOnStage ? 1 : IntroView.entranceScale)
                    .opacity(iconIsOnStage ? 1 : 0)
                    .animation(IntroView.entrance, value: iconIsOnStage)

                // Draws itself in and out on `isShown`; the loop keeps that
                // and `iconIsOnStage` from ever being true at once.
                OverlayView(model: pill)
            }
            .frame(height: 96)
            .accessibilityHidden(true)
            .entering(hasEntered, step: 1)

            Spacer(minLength: 0)

            VStack(spacing: 12) {
                Text("Welcome to Clio")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
                    .entering(hasEntered, step: 2)
                // Two sentences, one per line: each fits the card's width on
                // its own, and the break keeps them from re-wrapping into
                // three uneven lines.
                Text("Turn your voice into polished text.\n"
                     + "Works in Slack, Gmail and any other site or app.")
                    .font(.system(size: 15))
                    .lineSpacing(2.5)
                    .foregroundStyle(palette.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .entering(hasEntered, step: 3)
            }
            .padding(.bottom, 32)

            IntroMainButton(title: "Get Started", palette: palette, focus: focus,
                            action: getStarted)
                .entering(hasEntered, step: 4)
        }
        .padding(.bottom, 8)
        .onAppear { hasEntered = true }
        // Cancelled with the view, so the loop stops the moment the step
        // changes or the card closes.
        .task { await runDemo() }
    }

    /// What the demo says, as the meter hears it: 30 Hz levels shaped like
    /// two short words, a pause, and a longer one.
    static let phrase: [Float] = [
        0.05, 0.6, 0.85, 0.7, 0.3, 0.75, 0.55, 0.15, 0.05,        // "hel-lo"
        0.5, 0.9, 0.6, 0.8, 0.35, 0.1, 0.05, 0.05, 0.05,          // "there"
        0.1, 0.65, 0.8, 0.45, 0.7, 0.9, 0.6, 0.25, 0.7, 0.5, 0.2, // "how are you"
        0.05, 0.05, 0.4, 0.75, 0.55, 0.15, 0.05, 0.05,            // "…doing"
    ]

    /// Five band levels for one tick of the phrase: the level, shared out
    /// unevenly and differently each tick, the way a real spectrum is. A
    /// hash rather than a random source, so the demo is the same every time.
    static func bands(for level: Float, tick: Int) -> [Float] {
        (0..<5).map { band in
            let noise = sin(Double(tick) * 12.9898 + Double(band) * 78.233) * 43758.5453
            let share = Float(noise - noise.rounded(.down))   // 0…1
            return min(1, level * (0.45 + 0.75 * share))
        }
    }

    /// The icon and the pill, taking turns. The icon holds the stage for a
    /// few seconds; it leaves, and the pill runs a dictation with the
    /// timings the real loop has, shortened where the real one waits on
    /// hardware — opens listening, the meter breathes as it would on speech,
    /// a beat of transcribing with the ring lit, "Pasted" — and closes; the
    /// icon comes back. Neither is ever on stage while the other is.
    private func runDemo() async {
        pill.captureIsLive = true
        pill.isInteractive = false
        while !Task.isCancelled {
            // The icon's turn. Long enough on the first pass for the card's
            // own entrance to finish first.
            try? await Task.sleep(for: .milliseconds(3000))
            iconIsOnStage = false
            try? await Task.sleep(for: .milliseconds(320))

            // The pill's turn.
            pill.transcriptIsOnClipboard = false
            pill.state = .recording
            pill.level = 0
            pill.isShown = true
            // A phrase, not a sine: a few syllables, a breath, a few more.
            for (tick, level) in Self.phrase.enumerated() {
                pill.level = level
                pill.bands = Self.bands(for: level, tick: tick)
                try? await Task.sleep(for: .milliseconds(33))
            }
            pill.bands = []
            pill.state = .transcribing
            pill.isRingShown = true
            try? await Task.sleep(for: .milliseconds(700))
            pill.isRingShown = false
            try? await Task.sleep(for: .milliseconds(200))
            pill.state = .finished("")
            try? await Task.sleep(for: .milliseconds(900))
            pill.isShown = false
            // The pill's exit is 0.18 s; gone before the icon is back.
            try? await Task.sleep(for: .milliseconds(260))
            pill.state = .idle
            iconIsOnStage = true
        }
    }
}

// MARK: - Setup

/// Everything Clio cannot work without, as a live checklist, and one button
/// that does the first thing still missing.
///
/// The speech model is on the list because without one the app records and
/// then has nothing to hand the recording to. It is also the one thing that
/// takes a while, so it starts downloading the moment this step appears and
/// arrives while the permissions are being granted; the button reaches it
/// last and waits for it. The download carries on if the card is closed.
///
/// Microphone before Accessibility because it prompts inline; Accessibility
/// cannot be granted programmatically — the user has to visit System
/// Settings, and the only honest thing to do is send them there and watch.
/// The shortcut last: it has a default, so it is the one row already done,
/// and it is what the user reaches for the moment the card closes.
private struct SetupStep: View {
    @Bindable var coordinator: AppCoordinator
    let palette: IntroPalette
    var focus: FocusState<IntroFocus?>.Binding
    let startsDownload: Bool
    let dismiss: () -> Void
    @State private var hasEntered = false

    /// The model fetched here. Small enough to arrive while the user is still
    /// granting permissions, multilingual, and enough to prove the loop
    /// works; Settings ▸ Model has the rest.
    static let modelID = "openai_whisper-small_216MB"

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 24) {
                Text("Clio needs a few\nthings to work")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 12)
                    .entering(hasEntered, step: 1)

                VStack(alignment: .leading, spacing: 10) {
                    microphoneRow.entering(hasEntered, step: 2)
                    accessibilityRow.entering(hasEntered, step: 3)
                    modelRow.entering(hasEntered, step: 4)
                    shortcutRow.entering(hasEntered, step: 5)
                }
                .padding(.horizontal, 32)

                explanation
                    .padding(.horizontal, 32)
                    .entering(hasEntered, step: 6)
            }
            .padding(.top, 48)

            Spacer(minLength: 0)

            IntroMainButton(title: next.title(permissions), palette: palette, focus: focus,
                            isWaiting: next == .waitingForModel, action: advance)
                .animation(.easeOut(duration: 0.18), value: next)
                .entering(hasEntered, step: 7)
        }
        .padding(.bottom, 8)
        .onAppear {
            hasEntered = true
            permissions.beginPolling()
            models.refreshInstalled()
            if startsDownload { startDownloadIfNeeded() }
        }
    }

    private var permissions: PermissionsCoordinator { coordinator.permissions }
    private var models: ModelManager { coordinator.models }

    // MARK: Rows

    private var microphoneRow: some View {
        ChecklistRow(title: "Microphone",
                     mark: permissions.microphone.isGranted ? .done : .todo,
                     palette: palette) {
            status(permissions.microphone.isGranted ? "Granted" : "Not granted")
        }
    }

    private var accessibilityRow: some View {
        ChecklistRow(title: "Accessibility",
                     mark: permissions.accessibility.isGranted ? .done : .todo,
                     palette: palette) {
            status(permissions.accessibility.isGranted ? "Granted" : "Not granted")
        }
    }

    private var modelRow: some View {
        ChecklistRow(title: "Speech model", mark: modelMark, palette: palette) {
            status(modelStatus)
        }
        .help(modelHelp)
    }

    private var shortcutRow: some View {
        ChecklistRow(title: "Shortcut", mark: .done, palette: palette) {
            HotkeyRecorder(
                style: .intro,
                coordinator: coordinator,
                hotkey: Binding(
                    get: { coordinator.settingsStore.settings.hotkey },
                    set: { coordinator.settingsStore.settings.hotkey = $0 ?? .defaultHotkey }),
                other: coordinator.settingsStore.settings.secondaryHotkey,
                fallback: .defaultHotkey)
                .foregroundStyle(palette.primaryText)
                .introGlassButton(.utility, palette: palette)
                .help(shortcutHelp)
        }
    }

    private func status(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(palette.secondaryText)
            .monospacedDigit()
            .contentTransition(.numericText())
            .animation(.easeOut(duration: 0.18), value: text)
    }

    /// What each thing is for, in one paragraph — or, once the download has
    /// failed, why the model row is orange and what to do about it.
    @ViewBuilder
    private var explanation: some View {
        if let failure = modelFailure {
            Text("The speech model did not download: \(failure) "
                 + "Try again, or choose another in Settings ▸ Model.")
                .font(.system(size: 13))
                .foregroundStyle(.orange)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("The microphone lets Clio hear you, and Accessibility lets it "
                 + "paste the words where you are typing. The speech model "
                 + "turns your voice into text on this Mac, so nothing you say "
                 + "leaves it.")
                .font(.system(size: 13))
                .foregroundStyle(palette.secondaryText)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var shortcutHelp: String {
        let mode = coordinator.settingsStore.settings.hotkeyMode
        return (mode == .pushToTalk ? "Hold to dictate." : "Press to dictate.")
             + " Click to change."
    }

    // MARK: The button

    /// The first thing still missing, which is what the button does.
    enum Next: Equatable {
        case microphone, accessibility, download, retryDownload, waitingForModel, done

        @MainActor
        func title(_ permissions: PermissionsCoordinator) -> String {
            switch self {
            case .microphone:
                return permissions.microphone == .notDetermined
                    && PermissionsCoordinator.canRequestMicrophone
                    ? "Allow Microphone" : "Open Microphone Settings"
            case .accessibility:
                return permissions.accessibility == .notDetermined
                    ? "Allow Accessibility" : "Open Accessibility Settings"
            case .download: return "Download Speech Model"
            case .retryDownload: return "Try the Download Again"
            case .waitingForModel: return "Downloading Speech Model…"
            case .done: return "Start Dictating"
            }
        }
    }

    private var next: Next {
        if !permissions.microphone.isGranted { return .microphone }
        if !permissions.accessibility.isGranted { return .accessibility }
        if modelInstalled { return .done }
        if modelDownload != nil { return .waitingForModel }
        if modelFailure != nil { return .retryDownload }
        return .download
    }

    private func advance() {
        switch next {
        case .microphone:
            // Once macOS has recorded a denial it ignores the API request, so
            // a denied state goes straight to System Settings. So does a
            // process that cannot ask — see canRequestMicrophone.
            if permissions.microphone == .notDetermined,
               PermissionsCoordinator.canRequestMicrophone {
                Task { await permissions.requestMicrophone() }
            } else {
                permissions.openMicrophoneSettings()
            }
        case .accessibility:
            permissions.accessibility == .notDetermined
                ? permissions.requestAccessibility()
                : permissions.openAccessibilitySettings()
        case .download, .retryDownload:
            if let model { models.download(model) }
        case .waitingForModel:
            break
        case .done:
            dismiss()
        }
    }

    // MARK: Model

    private var model: CatalogModel? {
        models.catalog.first { $0.id == Self.modelID }
    }

    /// Any installed model counts. Someone reopening setup with Distil Large
    /// already on disk should not be told to download a smaller one.
    private var modelInstalled: Bool { coordinator.activeModel != nil }

    /// The download the row follows: ours, or — if one was started from
    /// Settings ▸ Model instead — that one, so the card never starts a
    /// second model downloading beside it.
    private var modelDownload: DownloadProgress? {
        models.downloads[Self.modelID] ?? models.downloads.values.first
    }

    private var modelFailure: String? {
        guard !modelInstalled, modelDownload == nil else { return nil }
        return models.failures[Self.modelID]
    }

    private var modelMark: ChecklistMark {
        if modelInstalled { return .done }
        if let progress = modelDownload { return .progress(progress.fraction) }
        if modelFailure != nil { return .failed }
        return .todo
    }

    private var modelStatus: String {
        if modelInstalled { return "Installed" }
        if let progress = modelDownload {
            guard progress.totalBytes > 0 else { return "Starting…" }
            return "\(Int((progress.fraction * 100).rounded(.down)))%"
        }
        if modelFailure != nil { return "Failed" }
        return model.map { Self.format($0.approximateBytes) } ?? "Not installed"
    }

    private var modelHelp: String {
        if let active = coordinator.activeModel { return active.displayName }
        if let progress = modelDownload, progress.totalBytes > 0 {
            return "\(Self.format(progress.receivedBytes)) of \(Self.format(progress.totalBytes))"
        }
        return model?.displayName ?? "Speech model"
    }

    /// Starts the model the moment setup appears, so it downloads while the
    /// permissions are being granted. Not when one is installed, already on
    /// its way, or has just failed — a failure waits for the button, rather
    /// than retrying every time the card is reopened.
    private func startDownloadIfNeeded() {
        guard !modelInstalled,
              models.downloads.isEmpty,
              models.failures[Self.modelID] == nil,
              let model else { return }
        models.download(model)
    }

    static func format(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

private enum ChecklistMark: Equatable {
    case todo
    case done
    case failed
    /// A download on its way; the circle fills as it goes.
    case progress(Double)
}

/// One thing Clio needs: a mark that turns green when it is in place, what it
/// is, and its state on the right.
private struct ChecklistRow<Trailing: View>: View {
    let title: String
    let mark: ChecklistMark
    let palette: IntroPalette
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            markView
                .frame(width: 20, height: 20)

            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(palette.primaryText)

            Spacer(minLength: 8)

            trailing()
        }
        .frame(minHeight: 22)
        .animation(.easeOut(duration: 0.18), value: mark)
    }

    @ViewBuilder
    private var markView: some View {
        if case .progress(let fraction) = mark {
            // The `circle` symbol, drawn by hand so it can fill. Sized and
            // weighted to sit where the symbol does.
            ZStack {
                Circle()
                    .stroke(palette.secondaryText, lineWidth: 1.5)
                Circle()
                    .trim(from: 0, to: max(0.04, fraction))
                    .stroke(palette.primaryText,
                            style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.25), value: fraction)
            }
            .frame(width: 15, height: 15)
        } else {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(symbolColor)
                .contentTransition(.symbolEffect(.replace))
        }
    }

    private var symbol: String {
        switch mark {
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .todo, .progress: return "circle"
        }
    }

    private var symbolColor: Color {
        switch mark {
        case .done: return Color(nsColor: .systemGreen)
        case .failed: return .orange
        case .todo, .progress: return palette.secondaryText
        }
    }
}

// MARK: - Shared

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

private func card(_ coordinator: AppCoordinator, _ step: IntroStep = .setup) -> some View {
    onGround(IntroView(coordinator: coordinator, startingAt: step, startsDownload: false) {})
}

#Preview("Welcome") {
    card(Preview.coordinator(), .welcome)
}

#Preview("Welcome — dark") {
    card(Preview.coordinator(), .welcome)
        .preferredColorScheme(.dark)
}

#Preview("Setup — nothing granted") {
    card(Preview.coordinator(microphone: .notDetermined, accessibility: .notDetermined,
                             installed: []))
}

#Preview("Setup — downloading") {
    card(Preview.freshCoordinator)
}

#Preview("Setup — granted, still downloading") {
    card(Preview.coordinator(installed: [],
                             downloads: [SetupStep.modelID: Preview.downloadInFlight]))
}

/// Denied is not the same as not-yet-asked: macOS ignores the API request once
/// it has recorded a denial, so these rows must offer System Settings instead.
#Preview("Setup — denied, download failed") {
    card(Preview.coordinator(
        microphone: .denied, accessibility: .denied, installed: [],
        failures: [SetupStep.modelID: "The network connection was lost."]))
}

#Preview("Setup — all set") {
    card(Preview.coordinator())
}

#Preview("Setup — dark") {
    card(Preview.coordinator(microphone: .granted, accessibility: .notDetermined,
                             installed: [],
                             downloads: [SetupStep.modelID: Preview.downloadInFlight]))
        .preferredColorScheme(.dark)
}
#endif
