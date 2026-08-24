# Scribe

Native macOS dictation. Hold a key, speak, get text pasted into whatever app
you're in. Fully offline — local models only.

Full design in [`docs/native-mac-dictation-spec.md`](docs/native-mac-dictation-spec.md).

## Status

**Milestones 0–5.** Scribe dictates: hold the shortcut, speak,
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
| 5 · Polish — VAD, sounds, history | ✅ |
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
  AudioDevices            CoreAudio input enumeration
  AudioDeviceMonitor      keeps the list live as devices come and go
  ModelCatalog            what we offer; bundled JSON + built-in fallback
  ModelTransport          Hugging Face listing and download, SHA-256 verified
  ModelManager            install, discover, delete, progress
  VoiceActivityTrimmer    cuts silence off both ends before transcribing
  WaveformIcon            the menu bar mark, drawn in three poses
  FeedbackPlayer          start / stop / cancel cues
  HistoryStore            last 20 transcripts, disk is opt-in
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

## Choosing a microphone

From the menu bar (Microphone ▸) or Settings ▸ Audio. Both list every device
with an input channel, with the built-in first and a checkmark on the current
choice, and both offer "System Default" naming what it currently resolves to.

Devices are stored by **CoreAudio UID, never `AudioDeviceID`** — the numeric id
is reassigned when something is unplugged and plugged back in, so persisting it
would silently point at a different microphone later.

Enumeration is CoreAudio rather than `AVCaptureDevice`: it needs no microphone
permission, so the picker works during onboarding before anything is granted,
and driving the engine needs an `AudioDeviceID`, which is the layer that has
one. `AVAudioEngine` has no API for input device selection on macOS; it is
`kAudioOutputUnitProperty_CurrentDevice` on the AUHAL unit underneath, and it
must be set **before** reading the input format — the format belongs to
whichever device the unit points at.

A chosen microphone that is no longer attached falls back to the system default
rather than failing the recording, and says so in both the menu and Settings.
Losing the words because a headset was unplugged is the worse outcome, but so
is silently recording from something else.

Bluetooth microphones carry the warning §9 asks for: recording from one
switches the headset into its bidirectional call mode, so anything playing
drops in quality for as long as the mic is open.

## What trimming silence is actually for

Not latency, for normal dictation — that assumption was measured and it was
wrong. Whisper transcribes in **30-second windows** and pads to fill one, so
cutting 8 seconds of silence off a 10-second clip buys nothing: both are a
single window, and both measured ~47 ms. The inference win only appears when
trimming removes a whole window:

```
padded  34.7s → 70 ms   (two windows)
trimmed  2.7s → 46 ms   (one window)
```

What it fixes below 30 seconds is **quality**. Whisper invents text over
silence. The same clip, padded and trimmed:

```
padded:  The quick brown fox jumps over the lazy dog. you
trimmed: The quick brown fox jumps over the lazy dog.
```

That trailing `you` is a hallucination, and it would have been pasted into
whatever you were typing in. The integration test asserts it stays gone.

A clip with no speech at all is never sent to the model — it reports "No speech
detected" instead of paying for a transcription that comes back as invented
text.

VAD is WhisperKit's own `EnergyVAD`, not Silero via onnxruntime as the spec
planned. It is already a dependency, so this needs no extra package and no
bundled ONNX model. Silero would slot in behind `VoiceActivityTrimmer.trim` if
noisy rooms ever prove the energy gate insufficient.

## The menu bar mark

Four capsule bars on a 5pt pitch, heights 6 / 16 / 10 / 6 in an 18×16 box, all
at full strength. Drawn in code rather than shipped as an asset, because the
menu bar needs it in three poses and generating them from one set of
proportions keeps them identical in weight:

- **resting** — the drawing as-is
- **live** — the same silhouette scaled by input level, so the mark itself is
  the meter while recording
- **muted** — the same shape dimmed, when Scribe cannot hear its shortcut

Every bar shares one centre line, which is what makes the live pose work: only
heights change, so it breathes instead of jumping.

Rendered at 15pt tall, not the design's 16 — the menu bar leaves about 16pt
once its own padding is out, and a mark that fills all of them sits proud of
the system items beside it.

It is a **template image**, so macOS tints it: black on a light menu bar, white
on a dark one, inverted while the menu is open. The black it is drawn in is
only ever a mask. A test asserts this, because losing it is invisible until
someone runs the other appearance.

The live pose is quantised to 8 steps and cached, or a steady voice would
redraw the menu bar at the recorder's 30 Hz.

To look at it after a change:

```sh
SCRIBE_ICON_DUMP=/tmp/icons swift test --filter IconDumpTests
```

## Two things that will bite you

**The overlay must never take focus.** It's a `.nonactivatingPanel` shown with
`orderFrontRegardless()`. If it becomes key, the frontmost app changes and the
paste lands in the wrong window. Test against Terminal, Safari, Slack, and a
full-screen app before believing it works.

**Never work inside the event tap callback.** macOS disables taps that are slow.
The callback matches the event and hops to the main actor, nothing more.
