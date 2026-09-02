# Working on Clio

Orientation for picking this up cold. [`README.md`](README.md) says what Clio
is and how to build it; this says how it fits together, what has been proven
versus merely written, and which mistakes have already been made so they are
not made twice.

Source, releases and the Sparkle feed all live in one public repo:
`petit-software/clio`. The feed is `docs/appcast.xml`, served by GitHub Pages at
`https://petit-software.github.io/clio/appcast.xml`.

## The loop

One dictation, end to end, with the file that owns each step.

| | | |
|---|---|---|
| 1 | key down, 180 ms hold threshold | `ClioCore/HotkeyManager` |
| 2 | pill appears — **before** anything slow | `ClioUI/AppCoordinator.beginRecording` |
| 3 | microphone starts, off the main actor (~425 ms) | `ClioCore/AudioRecorder` |
| 4 | key up → stop, samples returned | `AudioRecorder.stop` |
| 5 | silence trimmed off both ends | `ClioCore/VoiceActivityTrimmer` |
| 6 | Whisper on the Neural Engine | `ClioCore/WhisperKitEngine` |
| 7 | replacements, capitalisation | `ClioCore/TranscriptFormatter` |
| 8 | clipboard + synthesized ⌘V | `ClioCore/TextInjector` |

Every state is cancellable. Esc, or clicking the pill, at any point.

## Three targets, and why

- **`ClioCore`** — no SwiftUI. Everything with real logic, so it is testable
  without standing up an app. All 83 tests live here.
- **`ClioUI`** — every view, plus `AppCoordinator`. A **library**, not part of
  the executable, because Xcode renders `#Preview` dependably in a library and
  flakily in an executable. That is the only reason it exists.
- **`Clio`** — `@main` and the app delegate. Nothing else.

## Commands

```sh
swift build
swift test                                  # 83 tests, 10 suites, no network
./scripts/build-app.sh                      # Clio.app, Developer ID signed
./scripts/release.sh                        # notarized, stapled DMG in dist/
./scripts/generate-appcast.sh               # signs it, writes dist/appcast.xml
xcodegen generate && open Clio.xcodeproj    # Xcode: run, debug, profile, ⌘U
```

The Xcode project is generated from `project.yml` and not tracked. It is
`build-app.sh` expressed as a target — same plist, entitlements, icon script
and embedded Sparkle — signed with the Apple Development identity so
Accessibility stays granted across builds, and with `get-task-allow` injected
in Debug so the debugger can attach under the hardened runtime.

Gated suites and tools, all off by default:

```sh
CLIO_INTEGRATION=1 swift test --filter Integration        # downloads ~81 MB
CLIO_INTEGRATION=1 swift test --filter StartupLatency     # where start() spends time
CLIO_OVERLAY_DUMP=/tmp/x swift run Clio                   # every pill state to PNG
CLIO_OVERLAY_SHOW=recording swift run Clio                # the real panel, on screen
CLIO_OVERLAY_DARK=1 CLIO_OVERLAY_SHOW=transcribing swift run Clio
CLIO_OVERLAY_SIZE=extraLarge CLIO_OVERLAY_SHOW=recording swift run Clio      # the Settings ▸ Size choices
CLIO_OVERLAY_SHOW=sequence CLIO_OVERLAY_POSITION=bottomLeft swift run Clio   # a whole dictation, looping
CLIO_ICON_DUMP=/tmp/icons swift test --filter IconDumpTests
```

`CLIO_OVERLAY_SHOW` exists because glass samples what is behind the window, and
`ImageRenderer` has nothing behind it — it draws glass flat. Anything about the
pill's *surface* has to be judged on screen. Anything about its *layout* is
fine in the PNG dump.

`sequence` is how the transitions are judged: a still of any state says
nothing about how it arrived. To look at it frame by frame, capture the screen
in a loop with `screencapture -R` while it runs and tile the frames.

`swift run` has no bundle, so it cannot request the microphone. Use
`build-app.sh` for anything touching permissions.

## Releasing

Scripted, but the order matters:

1. Bump `CFBundleShortVersionString` in `Resources/Info.plist`, commit, push.
2. `scripts/release.sh` — refuses a dirty tree, builds, notarizes the app AND
   the DMG, staples both.
3. `scripts/generate-appcast.sh`
4. `gh release create vX.Y dist/Clio-X.Y.dmg --repo petit-software/clio`
5. **Then** `cp dist/appcast.xml docs/appcast.xml`, commit, push.

Step 5 last, always. An appcast naming a download that does not exist yet turns
every running copy's update check into a failure.

`CFBundleVersion` is the git commit count, stamped by `release.sh`. Sparkle
compares that, not the version string. GitHub Pages caches the feed for ten
minutes, so a check right after publishing will still be told it is up to date
— this is almost certainly what makes a fresh release look broken.

## Traps

Each of these cost real time. The reasoning sits in the code at each fix; this
is the index.

**Never write the event tap callback as a closure inside `HotkeyManager`.** The
manager is `@MainActor`, so a closure literal inherits main-actor isolation; as
a C function pointer it cannot hop, and the runtime check fires on the tap
thread and kills the process on the first keystroke. File-scope function only.
This shipped once.

**The overlay must never take focus.** `.nonactivatingPanel`, shown with
`orderFrontRegardless()`. If it becomes key the frontmost app changes and the
paste lands in the wrong window.

**The panel draws no window shadow.** `hasShadow` is false deliberately. macOS
caches a window's shadow from its content; the pill is translucent and resizes
per state, so the cache went stale and drew a hard outline around a pill that
was no longer that size.

**Adding a field to `Settings` used to wipe every install.** Swift's synthesized
decoder throws on a missing key even when the property has a default. `Settings`
decodes field by field with fallbacks — keep it that way, and add new fields to
`init(from:)`.

**Do not use SwiftPM's `Bundle.module`.** Its accessor looks for the bundle at
the root of the `.app`, falls back to a path hardcoded to the machine that
compiled it, then calls `fatalError`. `models.json` is a plain `Bundle.main`
resource with a compiled-in fallback.

**The tokenizer ships beside each model.** WhisperKit's CoreML folders carry no
`tokenizer.json`, so without this the first transcription quietly reaches for
the network — breaking the only promise the app makes.

**`withoutTimestamps` must stay false.** Whisper seeks between its 30-second
windows using the timestamps it emits. Suppressing them silently drops
everything after the first window: measured 154 characters against 993 on the
same minute of speech.

**Microphones are stored by CoreAudio UID, never `AudioDeviceID`.** The numeric
id is reassigned on replug.

**Never measure the pill on the hosting view that is on screen.** Forcing the
visible `NSHostingView` through `layoutSubtreeIfNeeded` / `fittingSize` runs
its layout at the new state's final values and throws away the layout
animation in flight — the capsule snapped to its new width while only the
label crossfaded, for as long as the overlay existed. `OverlayController`
measures a second hosting view that is never shown. The window itself is
never animated either: it grows before the pill does and shrinks after,
and the pill holds to its anchored edge in between — except during the
entrance, when it is centred so the capsule can open from its middle
(`isSettled` is what switches it over; it flips off screen, never on).

**Idle is never drawn.** The pill fades out saying whatever it said last and
the model is reset off screen. Drawing idle at once shrank the capsule to
nothing while it faded and clipped the last word.

**`injecting` looks exactly like `transcribing` in the pill.** The paste
takes about 150 ms, and a "Pasting" label for that long read as a flicker
between "Transcribing" and "Copied", never as a word. The menu bar still says
"Pasting…".

**The overlay tool modes do not start Sparkle.** From a bare `swift run`
binary its first-launch permission alert is modal, blocks the main actor, and
with it every timed step the `sequence` tool takes.

**The app icon must be re-fitted, not shipped as exported.** Icon Composer's iOS
exports fill the canvas because iOS masks icons itself; macOS does not, and
expects the body inset on the 824/1024 grid. `make-icon-master.swift` does that
and `make-iconset.sh` builds the `.icns` — a full-bleed export renders oversized
beside every other app.

**`grep -q` in a `pipefail` pipeline is a race.** grep exits on first match,
the producer dies of SIGPIPE, and the pipeline reports failure — but only when
the producer is slower. This made releasing fail at random. Capture output
first, then match.

**Sign every Mach-O inside Sparkle, not just the bundles.** It ships a bare
`Autoupdate` executable alongside `Updater.app` and two XPC services. Missing it
fails notarization, not the build.

## What is proven, and what is not

Verified by something repeatable:

- transcription, end to end, against the real model (`Integration`)
- long recordings are not truncated (`LongAudio`, 60s, three windows)
- every listed microphone actually records, each with a different level
- the update chain: signature verifies against the file GitHub serves, and a
  tampered copy is rejected
- a quarantined download passes Gatekeeper
- startup latency, measured per phase

Not verified, and worth knowing:

- **paste-back into other apps.** §5.7 asks for Terminal, Safari, Slack and a
  full-screen app. Nobody has done it. It is the highest-consequence untested
  path in the app.
- **Sparkle actually installing an update.** Every link has been checked
  individually; the whole chain has never been watched run.
- **the UI has no tests.** `ClioUI` is a library the test target could import,
  but nothing does yet. Previews cover the states; no assertions do.

## Open

- `scripts/release.sh` falls back to a keychain profile named `scribe-notary`,
  left from before the rename. notarytool credentials cannot be renamed without
  the App Store Connect key.
- The overlay's level meter and the menu bar mark are drawn separately and do
  not share code, though they share a design.
