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
| 6 · Ship — Developer ID, notarization, Sparkle, DMG | ✅ (app icon still missing) |

## Build

```sh
swift build            # library + executable
swift test             # unit tests, no network
./scripts/build-app.sh # Scribe.app, signed
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

## Signing

`build-app.sh` signs with the first **Developer ID Application** identity in the
keychain, and falls back to ad-hoc if there is none. Which one it used is the
last line it prints.

The difference is not cosmetic. A signature's *designated requirement* is what
TCC uses to decide whether this is the same app it granted Accessibility to:

```
ad-hoc:        cdhash H"bcd2d71e9b91918520f53fbb98073e09a4ece098"
Developer ID:  identifier "com.bartbak.scribe" and anchor apple generic
               and … certificate leaf[subject.OU] = TJ3ALYQV5G
```

The ad-hoc one is a hash of the binary, so every rebuild is a different app and
Accessibility has to be granted again. The Developer ID one names the bundle and
the team, which do not change when the code does — so permissions survive
rebuilds.

Hardened runtime is on either way, so the bundle is already in the shape
notarization needs. `SCRIBE_ADHOC=1` forces an ad-hoc signature;
`SCRIBE_NO_TIMESTAMP=1` skips the timestamp server for building offline.

## Releasing

```sh
./scripts/release.sh          # dist/Scribe-<version>.dmg, notarized and stapled
```

Refuses a dirty tree — a release nobody can check out again is not a release.
Credentials come from the keychain by name (`NOTARY_PROFILE`, default
`scribe-notary`), so the script holds no secrets. Create the profile once:

```sh
xcrun notarytool store-credentials scribe-notary \
    --key AuthKey_XXXX.p8 --key-id KEYID --issuer ISSUER
```

**Both the app and the disk image are notarized, in that order.** Stapling only
the DMG looks like it works — Gatekeeper accepts the app inside it — but
`stapler validate` on that app reports *"does not have a ticket stapled to it"*.
It passes only because the machine can reach Apple and check the record online.
Copy the app out of the DMG, be offline on first launch, and the same bundle is
"damaged". The ticket has to be in the app itself, which means notarizing it
before it goes into the image.

The app is zipped with `ditto`, not `zip`: it preserves the symlinks and
extended attributes a signed bundle is made of, and a plain `zip` can invalidate
the signature it is carrying.

Verified the way a download is: with a quarantine flag set on the DMG, `spctl`
reports `accepted — source=Notarized Developer ID`.

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

## Updates

Scribe ships outside the App Store, so Sparkle is the only route a fix has to
someone who already downloaded it.

- **Feed:** `https://petit-software.github.io/clio/appcast.xml`, served from
  this repo's `docs/` by GitHub Pages
- **Downloads:** releases on this repo, attached as DMGs
- **Signing:** EdDSA, private key in the developer's Keychain, public half in
  the signed `Info.plist`

Updates are offered, never applied silently. Scribe is held open by a global
event tap and may be mid-dictation; relaunching underneath someone in the
middle of a sentence is worse than waiting for them to say yes.

`SUPublicEDKey` lives in `Info.plist` deliberately — that file is signed and
notarized, so an attacker cannot swap the key that validates the payload
without breaking the signature. It is the same key ultra-swift uses: Sparkle's
own tooling says one key covers every app a developer ships.

Releasing:

```sh
scripts/release.sh              # signed, notarized, stapled DMG in dist/
scripts/generate-appcast.sh     # signs it and writes dist/appcast.xml
```

Then create the GitHub release, attach the DMG, and only then copy
`dist/appcast.xml` to `docs/appcast.xml` and push. That order matters: an
appcast pointing at a download which does not exist yet turns every running
copy's update check into a failure.

`generate-appcast.sh` refuses to run if the Keychain's key stops matching
`SUPublicEDKey` — updates signed with the wrong key are rejected by every
installed copy, and that is a miserable thing to discover from a user.

## Previews

Settings, the recording overlay and the onboarding window have `#Preview`
blocks — 12 of them, covering the states that are awkward to reach in the
running app: a fresh install with nothing granted, a microphone that has been
unplugged, the Bluetooth warning, every overlay state, and permissions denied
rather than merely not-yet-asked.

They stand on simulated dependencies (`Preview` in `UI/PreviewSupport.swift`,
DEBUG-only). That is not decoration: a preview of "microphone denied" has to
keep saying denied on a Mac where it is granted, so `PermissionsCoordinator`,
`AudioDeviceMonitor` and `ModelManager` each take a `simulating` initialiser
that reads no TCC state, touches no audio hardware, and scans no disk. Tests in
`SimulationTests` pin that fall-through shut — a simulated dependency that
quietly consults the real system is worse than none, because it looks right on
the machine that wrote it and wrong everywhere else.

Nothing preview-related ships: the release bundle contains zero preview
symbols.

The menu bar views have no previews on purpose. `MenuBarView` and
`MicrophoneMenu` are menu content, which Xcode renders as a plain list rather
than a menu, and `MenuBarLabel` is a 15pt icon better seen through the icon
dump above.

## Two things that will bite you

**The overlay must never take focus.** It's a `.nonactivatingPanel` shown with
`orderFrontRegardless()`. If it becomes key, the frontmost app changes and the
paste lands in the wrong window. Test against Terminal, Safari, Slack, and a
full-screen app before believing it works.

**Never work inside the event tap callback.** macOS disables taps that are slow.
The callback matches the event and hops to the main actor, nothing more.
