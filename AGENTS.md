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
| 3 | microphone starts, off the main actor (60 ms built-in, ~470 ms a USB display) | `ClioCore/AudioRecorder`, `InputCapture` |
| 4 | key up → stop, samples returned | `AudioRecorder.stop` |
| 5 | silence trimmed off both ends | `ClioCore/VoiceActivityTrimmer` |
| 6 | Whisper on the Neural Engine | `ClioCore/WhisperKitEngine` |
| 7 | replacements, capitalisation | `ClioCore/TranscriptFormatter` |
| 8 | clipboard + synthesized ⌘V | `ClioCore/TextInjector` |

Every state is cancellable. Esc, or clicking the pill, at any point.

## The meeting

One meeting, end to end.

| | | |
|---|---|---|
| 1 | started from the menu (named after the calendar's current event), or from the offer when a call app opens its mic | `ClioUI/AppCoordinator+Meetings`, `ClioCore/CallDetection` |
| 2 | calendar asked for the first time a meeting starts, never at launch | `ClioCore/MeetingCalendar` (EventKit) |
| 3 | mic streams through `AudioRecorder.onSamples` ("Me"); system audio through a process tap ("Others") | `AudioRecorder`, `ClioCore/SystemAudioCapture` |
| 4 | each stream cut at its pauses, chunks ≤ 25 s, stamped with when they were said | `ClioCore/SpeechSegmenter`, `MeetingSession.StreamFeed` |
| 5 | transcribed one at a time behind any dictation | `ClioCore/TranscriptionQueue` |
| 6 | added in time order, echo of the call in the mic dropped, Markdown rewritten | `ClioCore/MeetingRecord` |
| 7 | stop: drain, then a summary by Apple's on-device model (macOS 26) | `MeetingSession.stop`, `ClioCore/MeetingSummarizer` |
| 8 | the call app lets go of the mic for 30 s → the meeting stops itself | `CallWatch` |
| 9 | the folder is the library: every file read back, watched, searchable, edited in place | `ClioCore/MeetingLibrary`, `ClioUI/UI/LibraryView` |
| 10 | the sidebar is a day: its calendar events with their notes, then other notes, then dictations; search spans every day | `ClioCore/DayAgenda`, `MeetingCalendar.events(on:)` |

The library window is Clio's one real window: meetings down the side (the
live one first, then Today, Yesterday, months), dictations under them —
whatever Settings ▸ history keeps, nothing more — and the picked one as a
document. Clio has a Dock icon only while it is open.

## Three targets, and why

- **`ClioCore`** — no SwiftUI. Everything with real logic, so it is testable
  without standing up an app. All 198 tests live here.
- **`ClioUI`** — every view, plus `AppCoordinator`. A **library**, not part of
  the executable, because Xcode renders `#Preview` dependably in a library and
  flakily in an executable. That is the only reason it exists.
- **`Clio`** — `@main` and the app delegate. Nothing else.

## Commands

```sh
swift build
swift test                                  # 198 tests, 27 suites, no network
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
CLIO_INTEGRATION=1 CLIO_INTEGRATION_MODEL=<catalog id> swift test --filter "Integration|LongAudio"   # prove a model before offering it
CLIO_INTEGRATION=1 swift test --filter StartupLatency     # where start() spends time
CLIO_LONG_MEETING=60 swift test --filter LongMeeting      # an hour of meeting through a real session and an installed model; downloads nothing
CLIO_OVERLAY_DUMP=/tmp/x swift run Clio                   # every pill state to PNG
CLIO_OVERLAY_SHOW=recording swift run Clio                # the real panel, on screen
CLIO_OVERLAY_DARK=1 CLIO_OVERLAY_SHOW=transcribing swift run Clio
CLIO_OVERLAY_SIZE=extraLarge CLIO_OVERLAY_SHOW=recording swift run Clio      # the Settings ▸ Size choices
CLIO_OVERLAY_SHOW=sequence CLIO_OVERLAY_POSITION=bottomLeft swift run Clio   # a whole dictation, looping
CLIO_ICON_DUMP=/tmp/icons swift test --filter IconDumpTests
CLIO_INTRO_SHOW=1 swift run Clio                          # the intro card, alone, on screen
CLIO_INTRO_SHOW=setup swift run Clio                      # straight to its setup step
CLIO_INTRO_SHOW=downloading swift run Clio                # setup mid-download, simulated (also: waiting — all granted, model still coming)
CLIO_METER_DUMP=/tmp/meter CLIO_METER_VOICE=voice.wav swift test --filter MeterDumpTests  # the meter's bars for a recording: filmstrip, traces, numbers
CLIO_RECORDER_STRESS=40 Clio.app/Contents/MacOS/Clio      # start/stop 40 times in a hurry on each built-in and USB input, then listen to it, then switch between them; from the bundle, not swift run
CLIO_RECORDER_STRESS_ALL=1 CLIO_RECORDER_STRESS=40 Clio.app/Contents/MacOS/Clio   # the same, on Bluetooth headsets and iPhones too — ask whoever is wearing them first
CLIO_SETTINGS_SHOW=1 swift run Clio                       # the Settings window, alone
CLIO_MENU_SHOW=1 swift run Clio                           # the app, with its menu bar menu open; no intro, so Clio stays inactive as it is for a user
CLIO_SETTINGS_TAB=meetings CLIO_SETTINGS_SHOW=1 swift run Clio   # Settings on a given tab
CLIO_MEETING_SHOW=recording swift run Clio                # the meeting window, simulated: recording, silent, finishing, finished
CLIO_MEETING_PANE=transcript CLIO_MEETING_SHOW=recording swift run Clio   # …on a given pane
CLIO_OFFER_SHOW=1 swift run Clio                          # the "Take notes for …?" card
CLIO_TYPE=$'## Agenda\n- [ ] item' CLIO_LIBRARY_SHOW=live .build/debug/Clio   # types into the notes editor in the real window and reports how it laid out
CLIO_MARKDOWN_CHECK=1 .build/debug/Clio                  # every notes-editing rule through a real text view; exits non-zero on a failure
CLIO_OVERLAY_LIGHT=1 …                                    # any tool above, forced light (CLIO_OVERLAY_DARK forces dark)
CLIO_LIBRARY_SHOW=1 swift run Clio                        # the library window on sample meetings in a temp folder; =live adds a recording, =dictation picks one, =empty picks nothing
CLIO_LIBRARY_HEIGHT=460 CLIO_LIBRARY_SHOW=1 swift run Clio   # …in a short window, so the sidebar scrolls under its foot
CLIO_SYSTEM_AUDIO_FLIP_RATE=1 CLIO_SYSTEM_AUDIO_TEST=8 Clio.app/Contents/MacOS/Clio   # flips the output's rate mid-capture (and back): the tap must rebuild and keep hearing
CLIO_SYSTEM_AUDIO_TEST=7 CLIO_SYSTEM_AUDIO_OUT=/tmp/t.wav Clio.app/Contents/MacOS/Clio   # the tap, while something plays; from the bundle
CLIO_MEETING_TEST=24 Clio.app/Contents/MacOS/Clio         # a real meeting, into a temp folder, Markdown printed; play `say` meanwhile
```

`CLIO_METER_DUMP` exists because the meter was twice shipped without being
watched. `say -o v.aiff "…" && afconvert -f WAVE -d LEI16@48000 v.aiff v.wav`
makes a sample; judge the bars on the trace (do they pin, do they all move
alike) before judging them on screen.

`CLIO_OVERLAY_SHOW` exists because glass samples what is behind the window, and
`ImageRenderer` has nothing behind it — it draws glass flat. Anything about the
pill's *surface* has to be judged on screen. Anything about its *layout* is
fine in the PNG dump.

`sequence` is how the transitions are judged: a still of any state says
nothing about how it arrived. To look at it frame by frame, capture the screen
in a loop with `screencapture -R` while it runs and tile the frames.

`swift run` has no bundle, so it cannot request the microphone — TCC kills a
process that asks without a usage description, silently. `requestMicrophone`
checks for one first, so the intro tool's setup step offers System Settings
there instead of a button that would end the process. Use `build-app.sh` for
anything touching permissions.

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

**Capture does not go through `AVAudioEngine`, and must not go back.**
`InputCapture` opens the AUHAL unit directly with its output half switched
off. The engine was behind every capture failure this app has had, and they
were all the same fact seen from different sides: its input node and output
node are one unit, so a recording depended on the *output* device.

- A microphone at one sample rate and headphones at another would not start:
  -10868, "Audio engine failed to start". It is the mismatch that fails, never
  a particular rate, so plugging in headphones broke a microphone that worked
  a second earlier.
- Headphones changing format while a recording ran — a Bluetooth headset going
  into call mode because *any* app opened its microphone — raised an
  NSException in `AVAudioEngineGraph::InputAvailable`, on the engine's own IO
  thread, with nothing of ours on the stack to catch it. Four crash reports in
  ten minutes from the sweep on a built-in and a USB microphone, while
  dictation was being used in another copy of the app on AirPods. One of them
  was heap corruption instead.
- It caches formats, so an engine kept between recordings went stale when the
  hardware changed in between, and one pointed at a microphone stayed on it
  when asked to follow the system default again — a start that succeeded, on
  the wrong device.

With the output off, none of that can happen: no output device is opened,
every call returns a status, and a capture is made for one recording and
thrown away. `ObjCException` is still in the tree and nothing in the app calls
it any more.

**The capture's render callback is a function at file scope**, for the reason
the event tap's is, below. It runs on the IO thread and does three things:
render, copy into a ring, signal. A worker thread turns the ring into blocks
of 1024 frames — the size `MeterAnalyzer` is written for, whatever size the
hardware delivers in — and everything that allocates happens there.

**A capture cannot follow its device to a new format.** The unit does not
resample input, so the format asked of it is the device's own rate, and when
that moves (or the device goes away) the capture is replaced, not adjusted:
`AudioRecorder.deviceChanged`. Opening some devices makes them announce a
change that changed nothing, so the capture is asked `isStillValid` first —
restarting on every notification cost the first words of a recording.

**A start that does not throw is not a recording.** The stress pass only ever
asked whether `start` threw, and the documentation said it checked that
buffers arrived. The sweep now listens to each microphone and counts them,
and the recorder does the same while it runs: four seconds with nothing
delivered and the capture is rebuilt once, then reported.

**Nothing opens a Bluetooth headset or an iPhone without being asked.**
`AudioTransport.opensQuietly` is the rule: built-in and USB only. Opening a
headset's microphone drops it into call mode, and opening an iPhone's makes
the phone connect and say so — the sweep did both, forty times each, to
someone who was working. The sweep skips them unless `CLIO_RECORDER_STRESS_ALL`
is set, and the level in Settings shows a button for them instead of
listening.

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

**The binary must say which SDK it was built with.** SwiftPM links against
the installed SDK but writes the deployment target (14.0) into
`LC_BUILD_VERSION` as the SDK version, and macOS reads that number to decide
whether an app was built for the current design: below 26 it draws every
system control the old way — no Liquid Glass toolbar, sidebar, search field,
button or segmented control — while explicit `glassEffect` calls still work,
which is why the pill looked right and nothing else did. `declare-sdk.sh`
writes the real version; `build-app.sh` runs it before signing. For the
`swift run` tools: `scripts/declare-sdk.sh .build/debug/Clio --sign-ad-hoc`
after building, then run `.build/debug/Clio` directly. Check with
`otool -l <binary> | grep -A5 LC_BUILD_VERSION`.

**The library window has no toolbar, on purpose.** It once had one, bridged
from SwiftUI, and that was first blamed for the compatibility look (the SDK
version above was the real cause). Now the title bar is transparent with
nothing in it, `sceneBridgingOptions` is empty so SwiftUI adds no toolbar of
its own, the sidebar's controls sit along its foot (`safeAreaInset`) and a
document's along its own bottom (`DocumentBar`), floating over the page.

**`scrollEdgeEffectStyle` does nothing on the sidebar's `List`.** Rows
scrolled straight through the foot's controls, and under the search field,
with `.soft` set on the list for either edge. The foot draws its own
progressive blur: a material masked with a vertical gradient, behind the
inset. `CLIO_LIBRARY_HEIGHT` makes a window short enough to see it.

**System audio is a process tap, not ScreenCaptureKit.** ScreenCaptureKit
records a display to get at its sound, so it needs Screen Recording; a tap
needs only system-audio recording (`NSAudioCaptureUsageDescription`). The tap
is wired into a private aggregate device clocked by the current output, as
Apple's recipe does it, so when the output changes the capture is rebuilt
(`SystemAudioRecorder.outputDeviceChanged`).

**The tap sends nothing while nothing plays.** Measured: 0 s of samples in a
silent 10 s, and as long as the speech when `say` ran. A stream's sample count
is not its clock, so `StreamFeed` compares it with the wall clock and tells
the segmenter about any gap (`SpeechSegmenter.skip`) — without that, every
quiet stretch pulled the next "Others" line earlier. A refused permission
does not throw either; it is silence, which is why the window's warning is
worded "if others are talking".

**One WhisperKit pipeline, two callers.** The engine is an actor, but actors
re-enter at every `await` and `transcribe` awaits throughout: a dictation
during a meeting would have run on the pipeline alongside a chunk. Everything
goes through `TranscriptionQueue`, dictation first. Loading too — switching
models mid-chunk pulls the model out from under it.

**Meeting files start with front matter** (`clio`, `start`, `end`, `link`).
The library reads meetings back from the folder, and the human date line is
in the user's locale — parsing it back would break the first time someone
changed their region. The front matter is what is read; the rest is for
people.

**The tap is rebuilt when its clock moves, not only when the default output
changes.** AirPods go into call mode — a new sample rate on the same device —
the moment a call app opens their microphone. `SystemAudioRecorder` listens
on the output device itself, and acts on another queue, because removing a
listener from inside its own callback can deadlock.

**Markdown is rendered, not shown — but never rewritten.** The notes editor
keeps the Markdown in its text (the file, Copy and undo all see it) and hides
the syntax at the glyph level: `MarkdownStyle` marks `#`, `**`, backticks,
link brackets and fences with an attribute, and `MarkdownTextView`, as the
layout manager's delegate, gives those characters null glyphs. Bullets and
checkboxes keep their characters for the room they take, coloured clear, and
are drawn over (`drawDecorations`). The line with the caret shows its syntax
so it can be edited; a read-only editor — summaries, dictations — shows none.
`layoutManager` is touched, so this is TextKit 1; a TextKit 2 rewrite would
have to find another way to hide characters.

**Never size the notes editor by resizing its own text container.** SwiftUI
asks a representable for its size at several widths — a near-zero one for the
minimum among them — and whichever came last was the width the text was then
laid out at: typing filled a column a point wide, the editor grew, and
nothing could be read. `height(forWidth:)` measures a copy with a layout
manager of its own; the real container only follows the view. The editing
check could not see it — its text view is not inside SwiftUI. `CLIO_TYPE`
types into the real one, in the real window.

**A deadline is a race, not a task group.** Quitting waits for the meeting
for at most ten seconds; written as a task group, the group waited for the
stop that had lost anyway.

**Meetings stream; they do not buffer.** A meeting starts its `AudioRecorder`
with `maxSeconds: 0` and takes samples from `onSamples`. The dictation buffer
is preallocated for the whole recording, which for a two-hour call is half a
gigabyte.

**Microphones are stored by CoreAudio UID, never `AudioDeviceID`.** The numeric
id is reassigned on replug.

**Never measure the pill on the hosting view that is on screen.** Forcing the
visible `NSHostingView` through `layoutSubtreeIfNeeded` / `fittingSize` runs
its layout at the new state's final values and throws away the layout
animation in flight — the capsule snapped to its new width while only the
label crossfaded, for as long as the overlay existed. `OverlayController`
measures a second hosting view that is never shown, bound to a model of its
own so a state can be measured before the visible pill is told about it.
The window itself is never animated either: it grows before the pill does
and shrinks after, and the pill holds to its anchored edge in between —
except during the entrance, when it is centred so the capsule can open from
its middle (`isSettled` is what switches it over; it flips off screen,
never on).

**Fit the window, commit that, THEN change the state.** For a centred
position the window moves by half the growth to stay centred on the pill it
is about to hold. Done in the same update as the state change, SwiftUI saw a
pill whose origin in the window had not changed and grew it from its left
edge while the window jumped left: a lurch, then one-sided growth. `apply`
sets the frame first and forces one layout pass at the *old* state — the one
time forcing the visible view is right, because nothing is animating yet —
and only then writes the state. The centring frame in `OverlayView` sits
inside the state animation for the same reason: outside it, the placement
snapped and only the width eased.

**Idle is never drawn.** The pill fades out saying whatever it said last and
the model is reset off screen. Drawing idle at once shrank the capsule to
nothing while it faded and clipped the last word.

**`injecting` looks exactly like `transcribing` in the pill.** The paste
takes about 150 ms, and a "Pasting" label for that long read as a flicker
between "Transcribing" and "Copied", never as a word. The menu bar still says
"Pasting…".

**The intro's main button is not `.glassProminent`.** Given a label that
sets its own height, that style drew a rounded rectangle whatever border shape
it was told, and AppKit's blue focus ring with it, which
`.focusEffectDisabled` does not reach. `IntroProminentButtonStyle` is an ink
capsule with glass over it, and the card draws its own ring — 2pt, 4pt out —
on whichever of its buttons has focus. The main button takes focus whenever a
step appears; the ✕ only when tabbed to.

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
- every built-in and USB microphone starts, delivers buffers at the pace the
  meter expects, and is the one that was asked for after switching between
  them — the sweep, 40 cycles, run four times over without a failure
- the update chain: signature verifies against the file GitHub serves, and a
  tampered copy is rejected
- a quarantined download passes Gatekeeper
- startup latency, measured per phase
- system audio through the process tap, on built-in speakers
  (`CLIO_SYSTEM_AUDIO_TEST`), and a whole meeting — both streams, the queue,
  WhisperKit, the Markdown and an Apple Intelligence summary
  (`CLIO_MEETING_TEST`, `say` through the speakers)
- an hour of meeting through a real session and the real model
  (`LongMeeting`): large-v3 turbo transcribes it in about two minutes, both
  sides, and resident memory goes from 55 MB to a 161 MB peak — under the
  test's limit, but not flat, and not yet explained
- segmenting, echo removal, the queue's order, calendar matching, call
  detection decisions, a whole session on fake sources (drain on stop,
  wall-clock gaps, the mic muted while dictating, the summary), the Markdown
  round trip and the library's scan, search, edits and grouping:
  `MeetingTests`

Not verified, and worth knowing:

- **`InputCapture` on a Bluetooth headset, on an iPhone, and following the
  system default when it is one of those.** The sweep leaves them out unless
  told otherwise, and it has not been told otherwise since the capture was
  rewritten. AirPods as the default input is how this app is actually used.
- **the level in Settings ▸ Audio, on screen.** It builds and the monitor
  behind it is the recorder the sweep exercises, but nobody has watched the
  bar move, or confirmed the microphone is let go when the window closes.
- **paste-back into other apps.** §5.7 asks for Terminal, Safari, Slack and a
  full-screen app. Nobody has done it. It is the highest-consequence untested
  path in the app.
- **Sparkle actually installing an update.** Every link has been checked
  individually; the whole chain has never been watched run.
- **a first click on the offer card.** It accepts first mouse and may become
  key, which is the documented fix; a click sent inside the app cannot tell
  that from the old panel, and a click posted system-wide would move the
  user's pointer, so nobody has clicked it for real.
- **meetings on a real call.** The tap has heard `say`, not Zoom or a browser
  call; the offer and the auto-stop have only been tested as decisions, not
  watched against an app opening and closing its microphone; and the tap has
  not been run with headphones or AirPods as the output. A rate change on the
  built-in speakers rebuilds it and keeps hearing (`CLIO_SYSTEM_AUDIO_FLIP_RATE`);
  a Bluetooth device has not been tried.
- **the calendar prompt and EventKit reading real events.** Matching is
  tested on values; nobody has granted access and seen a meeting named.
- **a refused system-audio permission.** Assumed to deliver silence, as it
  does for a tap with nothing playing; not seen.
- **the UI has no tests.** `ClioUI` is a library the test target could import,
  but nothing does yet. Previews cover the states; no assertions do.

## Open

- `scripts/release.sh` falls back to a keychain profile named `scribe-notary`,
  left from before the rename. notarytool credentials cannot be renamed without
  the App Store Connect key.
- The overlay's level meter and the menu bar mark are drawn separately and do
  not share code, though they share a design.
- `HotkeyTests`' "Push to talk ends on the release of the chord that started
  it" counts ten milliseconds against sixty on the main actor and fails about
  half the time in a full `swift test`. It passes alone, every time.
