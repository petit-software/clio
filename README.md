# Scribe

Native macOS dictation. Hold a key, speak, get text pasted into whatever app
you're in. Fully offline — local models only.

Full design in [`docs/native-mac-dictation-spec.md`](docs/native-mac-dictation-spec.md).

## Status

**Milestones 0–4, less VAD.** Scribe dictates: hold the shortcut, speak,
and the text lands in the app you were typing in. Real transcription, on
device, no network.

`StubTranscriptionEngine` is still there behind the `TranscriptionEngine`
protocol — it makes the UI testable without loading a model.

| Milestone | State |
|---|---|
| 0 · Skeleton — menu bar, settings, onboarding, permissions | ✅ |
| 1 · Capture — hotkey down/up, push-to-talk and toggle | ✅ |
| 2 · ASR — WhisperKit, warm-load strategy | ✅ |
| 3 · Injection — paste with clipboard restore, secure-input fallback | ✅ |
| 4 · Models — catalog, download, verify, auto-discovery | ✅ |
| 5 · Polish — VAD, sounds, history | ⬜ overlay + settings done; VAD and sounds pending |
| 6 · Ship — Developer ID, notarization, Sparkle, DMG | ⬜ |

## Build

```sh
swift build            # library + executable
swift test             # unit tests, no network
./scripts/build-app.sh # Scribe.app, ad-hoc signed
open Scribe.app
```

The end-to-end test is off by default — it downloads ~81 MB and takes about
20 seconds. It is the only thing that actually proves the ASR path works, so
run it when touching the engine:

```sh
SCRIBE_INTEGRATION=1 swift test --filter Integration
```

It installs the tiny model, speaks a sentence through `say`, transcribes it,
and asserts the words come back.

Requires macOS 14+ and Swift 6.

`swift run` works for quick iteration but has no bundle, so it cannot request
the microphone — use `build-app.sh` for anything touching permissions.

**Ad-hoc signatures change every rebuild**, so macOS treats each build as a new
app and Accessibility must be re-granted each time. That stops once the app is
signed with a stable Developer ID identity (Milestone 6).

## Layout

```
Sources/ScribeCore/   no SwiftUI — testable on its own
  AppPaths                where things live on disk
  Settings                one Codable struct, one JSON file
  SettingsStore           debounced, atomic writes
  Hotkey                  key + modifiers, or a modifier-only chord
  HotkeyManager           CGEventTap, push-to-talk and toggle
  PermissionsCoordinator  mic + Accessibility, polled
  AudioRecorder           AVAudioEngine → 16 kHz mono Float32
  ModelCatalog            what we offer; bundled JSON + built-in fallback
  ModelTransport          Hugging Face listing and download, SHA-256 verified
  ModelManager            install, discover, delete, progress
  TranscriptionEngine     the protocol, plus a stub for testing
  WhisperKitEngine        CoreML on the Neural Engine — the real one
  TranscriptFormatter     replacements, capitalization, initial prompt
  TextInjector            clipboard + synthesized ⌘V, with restore
  DictationState          the state machine

Sources/Scribe/       the app
  ScribeApp           @main, MenuBarExtra + Settings scene
  AppCoordinator          wires it all together
  UI/MenuBarView          system menu
  UI/OverlayController    non-activating NSPanel
  UI/OverlayView          listening / transcribing / done pill
  UI/SettingsView         the seven tabs
  UI/OnboardingView       permission walkthrough
```

## Models

The catalog ships as `Resources/models.json`, copied into `Contents/Resources`
and read through `Bundle.main`. `ModelCatalog.builtIn` is a compiled-in copy of
the same list, used if the file is missing; a test asserts the two match so they
cannot drift.

**Not** a SwiftPM resource bundle. That accessor looks for its bundle at the root
of the `.app` (which codesign does not want), otherwise falls back to a build
path hardcoded to the machine that compiled it, and calls `fatalError` when it
finds neither — a build that works locally and crashes everywhere else.

The ids are the *quantized* variants. The spec's suggested sizes name them
implicitly: `distil-whisper_distil-large-v3` is 1.5 GB on disk, and the ~600 MB
model it means is `distil-whisper_distil-large-v3_594MB`.

Files are verified against the SHA-256 that Hugging Face reports as the LFS
`oid`, written to a `.partial` sibling and moved into place only once the hash
matches. A folder counts as installed when it contains a `.mlmodelc`, so an
interrupted download never reads as a working model.

Models already in `~/.cache/huggingface/hub` are found and reused. Those are
never deleted — they belong to whatever tool put them there.

**The tokenizer is installed alongside the model.** WhisperKit's CoreML folders
carry no `tokenizer.json`, so WhisperKit would fetch one from the network on
first load — which would quietly break the whole promise of the app. Each
install also pulls the matching `openai/whisper-*` tokenizer into a `tokenizer/`
subfolder (a subfolder because that repo has its own `config.json`, which next
to the model would overwrite WhisperKit's), and the engine is configured with
`download: false` so it cannot go looking.

## Two things that will bite you

**The overlay must never take focus.** It's a `.nonactivatingPanel` shown with
`orderFrontRegardless()`. If it becomes key, the frontmost app changes and the
paste lands in the wrong window. Test against Terminal, Safari, Slack, and a
full-screen app before believing it works.

**Never work inside the event tap callback.** macOS disables taps that are slow.
The callback matches the event and hops to the main actor, nothing more.
