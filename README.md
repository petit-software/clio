# Clio

Native macOS dictation. Hold a key, speak, and the text lands in whatever app
you were typing in. Entirely offline — Whisper runs on this Mac, and nothing
leaves it.

A menu bar app: no Dock icon, no window. Hold the shortcut, a small pill shows
the level while you talk, and on release the transcript is pasted into the
frontmost app. Models are downloaded once and run on the Apple Neural Engine.

Requires macOS 14+. Design notes in
[`docs/native-mac-dictation-spec.md`](docs/native-mac-dictation-spec.md).

## Status

Working end to end and signed for distribution. The app icon is the one
outstanding piece — Clio currently ships with the generic blank icon.

| | |
|---|---|
| Dictation | hotkey → record → transcribe → paste, with silence trimming |
| Models | catalog, download, SHA-256 verified, shared-cache discovery |
| Input | microphone picker, live device list, Bluetooth warning |
| Distribution | Developer ID signed, notarized, stapled DMG, Sparkle updates |
| Missing | app icon |

## Build

```sh
swift build              # library + executable
swift test               # 68 tests, no network
./scripts/build-app.sh   # Clio.app, signed with your Developer ID
open Clio.app
```

`swift run` has no bundle, so it cannot request the microphone — use
`build-app.sh` for anything touching permissions.

Two suites are off by default because they are slow or need hardware:

```sh
CLIO_INTEGRATION=1 swift test --filter Integration    # downloads ~81 MB
CLIO_ICON_DUMP=/tmp/icons swift test --filter IconDumpTests
```

The integration suite is the only thing that proves the ASR path actually
works: it installs the tiny model, speaks a sentence through `say`, transcribes
it, and asserts the words come back. Run it when touching the engine.

## Releasing

```sh
scripts/release.sh            # signed, notarized, stapled DMG in dist/
scripts/generate-appcast.sh   # signs it, writes dist/appcast.xml
```

Then create the GitHub release, attach the DMG, and **only then** copy
`dist/appcast.xml` to `docs/appcast.xml` and push. An appcast pointing at a
download that does not exist yet turns every running copy's update check into a
failure.

Updates are offered, never applied silently — Clio is held open by a global
event tap and may be mid-dictation.

## Layout

`ClioCore` is everything that is not SwiftUI, so the parts with real logic are
testable without standing up an app. `Clio` is the app: menu bar, overlay,
settings, onboarding.

```
Clio/          @main and the app delegate, nothing else
ClioUI/        every SwiftUI view, plus AppCoordinator — a library so Xcode
               can render its previews
ClioCore/
  Settings, SettingsStore     one Codable struct, one JSON file
  Hotkey, HotkeyManager       CGEventTap, push-to-talk and toggle
  PermissionsCoordinator      mic + Accessibility, polled
  AudioDevices, …Monitor      CoreAudio enumeration, live device list
  AudioRecorder               AVAudioEngine → 16 kHz mono Float32
  VoiceActivityTrimmer        cuts silence off both ends
  ModelCatalog, …Manager      install, discover, delete, verify
  TranscriptionEngine         the protocol, plus a stub for tests
  WhisperKitEngine            CoreML on the Neural Engine
  TranscriptFormatter         replacements, capitalization, prompt
  TextInjector                clipboard + synthesized ⌘V, with restore
  WaveformIcon                the menu bar mark, in three poses
  DictationState              the state machine

Clio/
  ClioApp, AppCoordinator     wiring
  UI/                         menu bar, overlay, settings, onboarding
  UI/PreviewSupport           simulated dependencies for #Preview (DEBUG only)
```

## Things that will bite you

Each of these cost real time. The reasoning lives in the code next to the fix.

**The overlay must never take focus.** It is a `.nonactivatingPanel` shown with
`orderFrontRegardless()`. If it becomes key, the frontmost app changes and the
paste lands in the wrong window.

**Never write the event tap callback as a closure inside `HotkeyManager`.** The
manager is `@MainActor`, so a closure literal there inherits main-actor
isolation; as a C function pointer it cannot hop, and the runtime isolation
check fires on the tap thread and kills the process on the first keystroke. It
must be a file-scope function. Never do work in the callback either — macOS
disables slow taps.

**Adding a field to `Settings` used to wipe every existing install.** Swift's
synthesized decoder throws on a missing key even when the property has a
default. `Settings` now decodes field by field with fallbacks; keep it that
way.

**Do not use SwiftPM's `Bundle.module`.** Its accessor looks for the resource
bundle at the root of the `.app`, then falls back to a build path hardcoded to
the machine that compiled it, then calls `fatalError`. That is a build that
works locally and crashes everywhere else. `models.json` is a plain
`Bundle.main` resource with a compiled-in fallback.

**The tokenizer is installed alongside each model.** WhisperKit's CoreML
folders carry no `tokenizer.json`, so without this the first transcription
quietly reaches for the network — breaking the one promise the app makes.

**Microphones are stored by CoreAudio UID, never `AudioDeviceID`.** The numeric
id is reassigned on replug, so persisting it points at a different microphone
later.

**Trimming silence is a quality fix, not a speed one.** Whisper pads to
30-second windows, so trimming below that changes nothing — measured, ~47 ms
either way. What it fixes is Whisper inventing text over silence, which would
otherwise be pasted into your document.

**Bluetooth microphones degrade playback.** Recording switches the headset into
call mode. Surfaced in the picker; not fixable.

**Not App Store distributable.** A session-level event tap and synthetic
keystrokes are incompatible with the App Sandbox. Direct download and Sparkle
only.
