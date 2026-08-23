# Whisperbar

Native macOS dictation. Hold a key, speak, get text pasted into whatever app
you're in. Fully offline — local models only.

Full design in [`docs/native-mac-dictation-spec.md`](docs/native-mac-dictation-spec.md).

## Status

**Milestone 0 — skeleton.** The app runs, the four UI surfaces are in place, and
the loop goes end to end: hotkey → record → overlay → clipboard → paste.

Transcription is stubbed. `StubTranscriptionEngine` returns obviously-fake
placeholder text on purpose — WhisperKit lands in Milestone 2 behind the
existing `TranscriptionEngine` protocol, and nothing above that seam changes
when it does.

| Milestone | State |
|---|---|
| 0 · Skeleton — menu bar, settings, onboarding, permissions | ✅ |
| 1 · Capture — hotkey down/up, push-to-talk and toggle | ✅ audio capture done; VAD pending |
| 2 · ASR — WhisperKit, warm-load strategy | ⬜ |
| 3 · Injection — paste with clipboard restore, secure-input fallback | ✅ |
| 4 · Models — catalog, download, verify, auto-discovery | ⬜ |
| 5 · Polish — VAD, sounds, history | ⬜ overlay + settings done |
| 6 · Ship — Developer ID, notarization, Sparkle, DMG | ⬜ |

## Build

```sh
swift build            # library + executable
swift test             # unit tests
./scripts/build-app.sh # Whisperbar.app, ad-hoc signed
open Whisperbar.app
```

Requires macOS 14+ and Swift 6.

`swift run` works for quick iteration but has no bundle, so it cannot request
the microphone — use `build-app.sh` for anything touching permissions.

**Ad-hoc signatures change every rebuild**, so macOS treats each build as a new
app and Accessibility must be re-granted each time. That stops once the app is
signed with a stable Developer ID identity (Milestone 6).

## Layout

```
Sources/WhisperbarCore/   no SwiftUI — testable on its own
  AppPaths                where things live on disk
  Settings                one Codable struct, one JSON file
  SettingsStore           debounced, atomic writes
  Hotkey                  key + modifiers, or a modifier-only chord
  HotkeyManager           CGEventTap, push-to-talk and toggle
  PermissionsCoordinator  mic + Accessibility, polled
  AudioRecorder           AVAudioEngine → 16 kHz mono Float32
  TranscriptionEngine     protocol + stub; WhisperKit goes here
  TranscriptFormatter     replacements, capitalization, initial prompt
  TextInjector            clipboard + synthesized ⌘V, with restore
  DictationState          the state machine

Sources/Whisperbar/       the app
  WhisperbarApp           @main, MenuBarExtra + Settings scene
  AppCoordinator          wires it all together
  UI/MenuBarView          system menu
  UI/OverlayController    non-activating NSPanel
  UI/OverlayView          listening / transcribing / done pill
  UI/SettingsView         the seven tabs
  UI/OnboardingView       permission walkthrough
```

## Two things that will bite you

**The overlay must never take focus.** It's a `.nonactivatingPanel` shown with
`orderFrontRegardless()`. If it becomes key, the frontmost app changes and the
paste lands in the wrong window. Test against Terminal, Safari, Slack, and a
full-screen app before believing it works.

**Never work inside the event tap callback.** macOS disables taps that are slow.
The callback matches the event and hops to the main actor, nothing more.
