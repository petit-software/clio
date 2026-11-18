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
| 1 | started from the menu (named after the calendar's current event), from the offer when a call app opens its mic, or from the same card when the calendar says a call is starting | `ClioUI/AppCoordinator+Meetings`, `ClioCore/CallDetection` |
| 2 | calendar asked for the first time a meeting starts, never at launch | `ClioCore/MeetingCalendar` (EventKit) |
| 3 | mic streams through `AudioRecorder.onSamples` ("Me"); system audio through a process tap ("Others") | `AudioRecorder`, `ClioCore/SystemAudioCapture` |
| 4 | each stream cut at its pauses, chunks ≤ 25 s, stamped with when they were said | `ClioCore/SpeechSegmenter`, `MeetingSession.StreamFeed` |
| 5 | transcribed one at a time behind any dictation | `ClioCore/TranscriptionQueue` |
| 6 | added in time order, echo of the call in the mic dropped, Markdown rewritten | `ClioCore/MeetingRecord` |
| 6½ | stop, with the speaker models installed: the call's side, written to a temporary file as it arrived, is diarized; each of the others' lines goes to the voice that spoke most of it ("Speaker 1", "Speaker 2"); a summary model names the voices the conversation names; the file is deleted | `ClioCore/SpeakerDiarization` (`StreamRecording`, `SpeakerAssignment`), `SpeakerDiarizer`, `SpeakerNamer`, `MeetingSession.identifyVoices` |
| 6¾ | each voice's print is compared with those of earlier meetings: one they are sure of is named from them alone, the rest go to the model as evidence; then the prints are kept, under the names they ended with | `ClioCore/VoiceMemory` (`VoiceprintMatcher`), `ClioUI/AppCoordinator+Voices` |
| 6⅞ | where Settings ▸ Meetings keeps audio: both sides encoded to AAC beside the notes (`Name.me.m4a`, `Name.others.m4a`), on the meeting's clock, renamed and trashed with the Markdown; played from the meeting's page | `ClioCore/MeetingAudio`, `ClioUI/UI/MeetingPlayer` |
| 7 | stop: drain, then a summary — by Apple's on-device model (macOS 26), or by a downloaded GGUF run by llama.cpp, whichever Settings ▸ Model names; any saved meeting can be summarized again from its ⋯ menu | `MeetingSession.stop`, `ClioCore/MeetingSummarizer`, `LocalSummaryModel`, `ClioUI/AppCoordinator+Summaries` |
| 8 | the call app lets go of the mic for 30 s → a card says the call seems to have ended and counts fifteen seconds down; Keep Recording, or the meeting stops itself | `CallWatch`, `AppCoordinator.offerToKeepRecording` |
| 9 | the folder is the library: every file read back, watched, searchable, edited in place | `ClioCore/MeetingLibrary`, `ClioUI/UI/LibraryView` |
| 9½ | a recording made elsewhere, dropped on the window or chosen from the menu, is put through a session of its own — the file as the call's side, a clock that runs as fast as it is read — and comes out a meeting like any other | `ClioCore/MeetingImport`, `ClioUI/AppCoordinator+Import` |
| 9¾ | with Settings ▸ Meetings ▸ Other apps on: an MCP server on 127.0.0.1 answers three read-only tools — find meetings, read one, read its transcript; and `clio://` links open a meeting, a search, or start notes | `ClioCore/MCPServer` (`MCPProtocol`), `MeetingTools` (`AppLink`), `ClioUI/AppCoordinator+Sharing` |
| 10 | the sidebar is a day: its calendar events with their notes, then other notes, then dictations; search spans every day | `ClioCore/DayAgenda`, `MeetingCalendar.events(on:)` |

The library window is Clio's one real window: meetings down the side (the
live one first, then Today, Yesterday, months), dictations under them —
whatever Settings ▸ history keeps, nothing more — and the picked one as a
document. Clio has a Dock icon only while it is open.

## Three targets, and why

- **`ClioCore`** — no SwiftUI. Everything with real logic, so it is testable
  without standing up an app. All 276 tests live here.
- **`ClioUI`** — every view, plus `AppCoordinator`. A **library**, not part of
  the executable, because Xcode renders `#Preview` dependably in a library and
  flakily in an executable. That is the only reason it exists.
- **`Clio`** — `@main` and the app delegate. Nothing else.

## Commands

```sh
swift build
swift test                                  # 276 tests, 37 suites, no network (one of them over HTTP, on the loopback address)
./scripts/build-app.sh                      # Clio.app, Developer ID signed
./scripts/release.sh                        # notarized, stapled DMG in dist/
./scripts/generate-appcast.sh               # signs it, writes dist/appcast.xml
./scripts/generate-cask.sh                  # the Homebrew cask for that DMG, into Casks/ — this repo is its own tap
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
CLIO_INTEGRATION=1 swift test --filter SanitizerIntegration   # what the installed speech model says after three seconds of silence, segment by segment; downloads nothing
CLIO_INTEGRATION=1 swift test --filter ModelResidency     # load, use and free the installed speech model and GGUF: does the memory come back; downloads nothing
CLIO_INTEGRATION=1 CLIO_SUMMARY_MODEL=~/Library/Application\ Support/com.bartbak.clio/models/<id>/<file>.gguf swift test --filter SummaryModelIntegration   # a GGUF through llama.cpp: a prompt, then a whole meeting; downloads nothing
CLIO_INTEGRATION=1 swift test --filter SpeakerIntegration   # the real speaker models on macOS's own voices: turns told apart, then a whole call through a session, Whisper and a summary model; the first run downloads 17 MB into /tmp
CLIO_SPEAKER_MINUTES=60 CLIO_INTEGRATION=1 swift test --filter aLongCall   # an hour of call through the diarizer alone: the time and the memory
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
CLIO_PREVIEW=countdown swift run Clio                     # one of Settings ▸ About ▸ Developer's previews, without the click: dictation, nothing, error, call, calendar, countdown, welcome, setup
CLIO_MENU_SHOW=1 swift run Clio                           # the app, with its menu bar menu open; no intro, so Clio stays inactive as it is for a user
CLIO_SETTINGS_TAB=meetings CLIO_SETTINGS_SHOW=1 swift run Clio   # Settings on a given tab
CLIO_SETTINGS_HEIGHT=1000 CLIO_MEMORY_GB=8 CLIO_SETTINGS_TAB=model CLIO_SETTINGS_SHOW=1 swift run Clio   # …tall enough to show the whole tab (nothing there can scroll it), as an 8 GB Mac would list the models
CLIO_SETTINGS_PROMPT=1 CLIO_SETTINGS_HEIGHT=760 CLIO_SETTINGS_TAB=meetings CLIO_SETTINGS_SHOW=1 swift run Clio   # …with the summary's instructions open
CLIO_MEETING_SHOW=recording swift run Clio                # the meeting window, simulated: recording, silent, refused, finishing, finished
CLIO_MEETING_PANE=transcript CLIO_MEETING_SHOW=recording swift run Clio   # …on a given pane
CLIO_OFFER_SHOW=1 swift run Clio                          # the "Take notes for …?" card
CLIO_TYPE=$'## Agenda\n- [ ] item' CLIO_LIBRARY_SHOW=live .build/debug/Clio   # types into the notes editor in the real window and reports how it laid out
CLIO_MARKDOWN_CHECK=1 .build/debug/Clio                  # every notes-editing rule through a real text view; exits non-zero on a failure
CLIO_OVERLAY_LIGHT=1 …                                    # any tool above, forced light (CLIO_OVERLAY_DARK forces dark)
CLIO_LIBRARY_SHOW=1 swift run Clio                        # the library window on sample meetings in a temp folder; =live adds a recording, =dictation picks one, =event the call to come, =empty nothing
CLIO_PALETTE_SHOW=pricing CLIO_LIBRARY_SHOW=1 swift run Clio   # the search palette open, with that typed (=1 for empty)
CLIO_LIBRARY_HEIGHT=460 CLIO_LIBRARY_SHOW=1 swift run Clio   # …in a short window, so the sidebar scrolls under its foot
CLIO_LIBRARY_WIDTH=1240 CLIO_LIBRARY_SHOW=1 swift run Clio  # …wide, so the page takes its wide margins (the breakpoint is 520 pt of page)
CLIO_SCROLLER_SHOW=1 CLIO_LIBRARY_HEIGHT=460 CLIO_LIBRARY_SHOW=1 swift run Clio   # the sidebar scrolled a little, its scroll bar kept on screen
CLIO_MEETING_PANE=transcript CLIO_SCROLLER_SHOW=1 CLIO_LIBRARY_WIDTH=1100 CLIO_LIBRARY_SHOW=1 swift run Clio   # a long page scrolled under the toolbar, for its fade
CLIO_SYSTEM_AUDIO_FLIP_RATE=1 CLIO_SYSTEM_AUDIO_TEST=8 Clio.app/Contents/MacOS/Clio   # flips the output's rate mid-capture (and back): the tap must rebuild and keep hearing
CLIO_SYSTEM_AUDIO_TEST=7 CLIO_SYSTEM_AUDIO_OUT=/tmp/t.wav Clio.app/Contents/MacOS/Clio   # the tap, while something plays; from the bundle
CLIO_SYSTEM_AUDIO_PROBE=1 Clio.app/Contents/MacOS/Clio    # is a tap allowed to hear? plays the inaudible tone and listens for it; exits 0 when allowed
CLIO_VOICEPRINT_REPORT=1 Clio.app/Contents/MacOS/Clio     # the distances between the voices kept: same person, different people — what the matcher's thresholds should sit between; reads the store, changes nothing
CLIO_MEETING_TEST=24 Clio.app/Contents/MacOS/Clio         # a real meeting, into a temp folder, Markdown printed; play `say` meanwhile
CLIO_SUMMARIZE="$HOME/Documents/Clio Meetings/<file>.md" Clio.app/Contents/MacOS/Clio   # Summarize Again on that file with the model Settings names; writes into it, prints the summary
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

6. `scripts/generate-cask.sh`, then commit and push `Casks/clio.rb` with
   the appcast. This repository is its own Homebrew tap (`Casks/` at its
   root), so the cask is live when it is on `main` — after the release
   exists, for the appcast's reason.

Step 5 last of those that are served, always. An appcast naming a download that does not exist yet turns
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

**"Keep model in memory" read nothing for eleven releases.** The toggle
was in the first commit and the value was stored, and no code consulted it:
the speech model stayed loaded from the first dictation to quit either way,
and a summary model let itself go after two minutes either way.
`AppCoordinator+Residency` honours it now — off, the speech model is freed
after each dictation and after a meeting stops, and a summary model five
seconds after its last request — and `ModelResidency` measures what freeing
gives back. Activity Monitor understates a loaded speech model: the Neural
Engine's share of a CoreML model is charged to the system's `aned`, so
large-v3 turbo adds only 201 MB to Clio's own row. A setting nobody has
measured is a toggle that may do nothing.

**Three kinds of model share one folder, and must never be confused.**
`models/<id>/` holds WhisperKit folders (`.mlmodelc` inside), summary
models (one `.gguf` inside) and the speaker models (`speaker_segmenter/`
and two more, each compiled model three folders down);
`InstalledModel.kind` is read from the folder's contents and every fallback
that reaches for "the first installed model" filters by it — `LongMeeting`
did not, and once a GGUF was the largest thing installed it "transcribed"
an hour in two seconds, to nothing — — `AppCoordinator.activeModel` once did not, and a GGUF
offered to WhisperKit is a dictation that fails. A single-file model is
listed from its repo's root (`CatalogModel.fileName`, `repoPath`) and still
installed as a folder, so discovery, size, delete and the shared-cache rule
are the same code for both.

**A model from elsewhere is a symbolic link, never a copy.** "Add a Model
You Have…" in Settings ▸ Model links a WhisperKit folder, or a GGUF inside a
folder of its own, into `models/` (`ModelManager.link`), so discovery,
selection, size and the rows see it like any download. `isDescendant`
resolves the parent and not the last component for this reason: resolving
the link would put the model outside our folder and hide Delete, when
deleting it removes the link and nothing else. A linked WhisperKit folder
without a `tokenizer/` beside it makes WhisperKit reach for the network on
first load — the same trap as the shared cache.

**llama.cpp is a binary target, not MLX.** MLX Swift compiles its Metal
shaders only under Xcode, and `swift build` is how this app is built and
tested. llama.cpp's own release ships an XCFramework; `Package.swift` pins
one build by URL and checksum, and `build-app.sh` embeds the framework
beside Sparkle, thinned to arm64 and re-signed — its release signature is
ad-hoc and would fail notarization. `LocalSummaryModel` runs on a dispatch
queue of its own (an actor with a `DispatchSerialQueue` executor): a summary
is tens of seconds of synchronous C calls, which the cooperative pool must
not host. The weights are loaded once; the context is made per request, to
fit the prompt counted in real tokens plus room for the answer, in steps of
2k, under a ceiling. The KV cache is what a context costs — 143 KB a token
on Qwen3 4B: 0.7 GB at 4k, 1.6 at 10k, 3.1 at 20k, 4.5 at 30k
(`ModelResidency`, contextCost) — so the ceiling is the lower of two limits:
by the Mac (8k on 8 GB, 16k to 16 GB, 32k above) and by the model, weights
and cache together under half the memory. The cache per token is estimated
from the weights' size, calibrated on that one model; a 12B model's has not
been measured. A piece is still cut at three characters a token — a
transcript's timestamps tokenize at about 3.5 — so one in a language that
tokenizes worse than English still fits.

**Those invited are in the summary's prompt, with a warning.** Given the
list alone, Qwen3 4B worked out who "Others" must be by elimination and
wrote "release notes to be written by Tom" — Tom was invited and never
named. `MeetingSummarizer.attribution` follows the list and says it is for
spelling names only; `SummaryModelIntegration` fails if Tom comes back.

**A `DisclosureGroup` in a grouped Settings form shows nothing.** It drew
its label, left room under it, and never its content. The summary's
instructions are plain rows of the section with an Edit… button.

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

**The library's toolbar: the sidebar button, the document's name, the pane.**
The window keeps an `NSToolbar` with SwiftUI's toolbars and title bridged in.
The sidebar button is Clio's, a toolbar item on the sidebar column with the
system's removed (`.toolbar(removing: .sidebarToggle)`): SwiftUI hosts the
system's as a view of its own, so setting its `NSToolbarItem.image` changes
nothing. SwiftUI moves the item beside the traffic lights when the sidebar
hides. `navigationSplitViewColumnWidth` must come after the toolbar
modifiers on the column, or it is not read and the sidebar opens at 209. The document's name and date are a toolbar item of Clio's
own (`DocumentTitle`, at `.navigation`, its glass hidden): the window's title
is hidden because, bridged, it could not take a menu — `toolbarTitleMenu`
drew nothing — and the chevron for who was invited has to follow the name.
Search is pushed to the trailing edge by a flexible space
(`SearchToolbarItem`); a placement alone lands beside the title.
Nothing else goes in it: the sidebar's day sits at its head — the date
("18 Nov"), "Today" / "Yesterday" / "Tomorrow" over it in a line that is
there whether or not the day has a name, so nothing moves (`dayHeader`),
with the list fading out under it as it does over the foot — Take Notes at
its foot, and beside it the arrows to the days either side, shown only
while the pointer is over the sidebar; nothing along either foot is glass. Take Notes is a capsule as
wide as its words with four points more at its sides than above and below
(`TakeNotesButtonStyle`), and a document's controls along its own bottom
(`DocumentBar`), floating over the page. An event's page — a call with no
notes yet — has its name breaking at 320 points, the date under it, how
long and who on the line after, and two buttons padded like the sidebar's:
Write Notes, which makes the event a note with nothing recorded
(`MeetingRecord.notes(for:)`), and Take Notes, grey beside the sidebar's
ink one and ink itself when the sidebar is hidden. A note with no
transcript has Record in the middle of its bar: the recording is started
into those notes (`MeetingSession.adopt`), one file, not a second meeting. The button was drawn by hand as an overlay for one
commit; laid out past the title bar's safe area it sat wrong and looked it.

**`scrollIndicators(.hidden)` does nothing on it either.** A `List` on macOS
is an `NSTableView` in its own scroll view, and the modifier never reaches
the scroller. `ThinScrollers`, in the list's background, walks up to the
scroll view and swaps in `ThinScroller`: a 7-point line at 22% of the text
colour, no track, on the sidebar and every page alike. It fades itself: an
overlay scroller fades by drawing its knob at a falling alpha, which a
custom `drawKnob` never sees, so the bar stayed on screen from the launch
flash onward whatever the pointer did. Now it starts at alpha 0 and a
tracking area on the installer view — the list's or page's own size; a
page's scroll view runs under the sidebar on macOS 26 and spans the window
— fades it in while the pointer is over it and out when it leaves. A subclass must say `isCompatibleWithOverlayScrollers`
or the bar comes back legacy and always visible. `CLIO_SCROLLER_SHOW`
keeps it on screen; nothing else makes an overlay scroller sit still.

**The toolbar has no backdrop of its own; each page fades under it.** The
band AppKit draws under a window's `NSToolbar` is blur with a hard edge, and
nothing softens it: `scrollEdgeEffectStyle(.soft)` and `scrollEdgeEffectHidden`
on the page changed nothing (captured identical), and AppKit's own
`NSScrollEdgeEffectStyle` (26.1) is offered only to accessory view
controllers. So the title bar is transparent (`titlebarAppearsTransparent`)
and every page draws `pageTopFade` — the same `EdgeFade` as the sidebar's
foot: the window's own colour, from clear to solid, and no material — a
material is never clear, and over an empty page it drew a grey band
(#F8F8F8 on white) where nothing was fading. A page without it puts the
title on the text.

**The window's glyphs are SVGs, not symbols.** `LibraryIcon` draws them
from Resources/Icon/Library — copy, ⋯, sidebar, chevrons, the rows'
calendar and transcript, the notes' to-dos — as `SettingsIcon` does for the
Settings tabs. Menus keep their SF Symbols.

**A live meeting's recorder is the pill, at the foot of its page.**
`MeetingPill` is the dictation pill's surface, dot, meter and ring, light
in light mode and black in the dark as a dictation's is, 37 points high, with the
time and a stop (⌘.), centred over the `DocumentBar` —
laid over it, not inside its `GlassGroup`: inside, its surface and
everything on it were blended into the group's glass and all but vanished.
The meter reads `MeetingSession.micLevel`/`micBands`.

**Search is a palette, not a field.** `CommandPalette`, over the whole
library window: ⌘F or the magnifier top right (`SearchToolbarItem`, on
every page). The sidebar is a day and has no search. A document's ⋯ is
along its foot, beside Copy; the toolbar holds the title and search only.

**One chevron.** `Chevron` is the grey mark on everything that
opens or steps — the pane pull-down, the participants, the day arrows — at
38% of the ink, as the pill's microphone chevron is. Draw no other.

**A page's margins have one breakpoint.** Past 520 points of page,
`PageMargins` adds three more of each: 12 → 48 under the toolbar, 28 → 112
at the sides. Narrower, nothing is added, so the panes' own paddings are
still the whole story. `CLIO_LIBRARY_WIDTH` shows either side of it.

**`scrollEdgeEffectStyle` does nothing on the sidebar's `List`.** Rows
scrolled straight through the foot's controls, and under the search field,
with `.soft` set on the list for either edge. The foot and the head draw
their own fade (`EdgeFade`) behind the inset. `CLIO_LIBRARY_HEIGHT` makes a window short enough to see it.

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

**Silence from the call is looked into, not guessed at.** After twenty
seconds of nothing a meeting runs `SystemAudioProbe` once: a 150 Hz tone at
−74 dBFS to the default output, and a second tap that takes in Clio's own
process and nothing else. The meeting's tap cannot do it — it leaves Clio's
own sound out on purpose. The tone coming back means the call is only
quiet, and nothing is said; exact zeros means refused, and the window says
so; a probe that could not run leaves the old "if others are talking".
Clio has no process object in the HAL until it has made a sound, so the
tap is opened after `play`, with retries.

**A sentence over a stretch with no sound in it was not said.**
`TranscriptSanitizer` drops a segment that starts past the end of the
audio, cuts one that runs past it, drops a last single word the model was
unsure of — and, the rule that matters, drops a segment with next to no
sound under it (`Sound`: 20 ms frames, a frame counting at a twenty-fifth
of the loudest). The first three are Biscotti's and did not catch what
Whisper actually does: given three seconds of silence after speech,
large-v3 wrote "Thank you." at 0.80, starting where the speech stopped.
The fourth does, and loses nothing said (`SanitizerIntegration`, the
scripted calls, five minutes of `LongMeeting`). The probabilities come
from each segment's token log-probabilities, so word timestamps and their
second pass stay off.

**The speaker models must never be given digital silence.** The recording
of the call is exact zeros wherever the tap sent nothing: before its first
sound, and through every stretch nothing played. A turn that followed forty
seconds of zeros came back as a different person from the same voice's
later turns — as far from them as from the other speaker (0.86 against
0.89) — and the last turns of a recording split off the same way.
`SpeakerDiarizer.removeDigitalSilence` puts noise at −70 dBFS in place of
every zero and fills the end out to a whole 30-second window; with it, 48
turns of two voices all land on the right one, with any lead of silence.
Why it works is a guess (features normalised per window); that it does is
measured, in `SpeakerIntegration`.

**The call's audio exists only until the voices are told apart.**
`StreamRecording` is written only when a diarizer is set, into a folder in
the temporary directory named for the process, and deleted at the end of
`identifyVoices` whatever happened, on `abandon`, and on a failed start.
At launch every folder whose process is gone is removed — by process, so a
second copy of Clio (any tool here) never deletes the recording of a
meeting the first is in. Time in the file is time in the meeting: the
stream's late start and the tap's gaps are written as silence by
`StreamFeed`, which is how a span becomes a line's voice with no mapping.

**Telling an hour of call apart holds it all in memory.** SpeakerKit takes
one array. Measured: an hour in 18 s, 1.3 GB at its peak, and about 270 MB
that is not given back until quit (the same after a second run, so kept,
not leaked). One copy of the samples, changed in place; a second cost
another 230 MB an hour.

**A voice is a number on the line, not a kind of speaker.** `MeetingLine.voice`
beside `speaker`, so "Me"/"Others" and everything that tests them is as it
was. The name is in the front matter (`speaker-2: Tom`, or
`speaker-2-guess:` when a model gave it) and at the head of each line; a
name reads back to its number through the front matter. A guess never
replaces a name the user gave, and a name may not be "Me", "Others" or
"Speaker 3" — they would read back as something else.

**The matcher's thresholds are Biscotti's, not Clio's.** Accept under
0.50, probable under 0.30, sure under 0.20 with three meetings, two of them
confirmed, and nobody else near — calibrated by its author on real meetings
with the same embedder and SpeakerKit release (same person mostly under
0.32, the closest two different people 0.62). Clio's only numbers are
synthetic voices: 0.05–0.11 for one voice across four recordings, 0.85–0.94
between two. `CLIO_VOICEPRINT_REPORT` prints the same two lists from the
real store; move the thresholds on that, not on the test.

**Voiceprints are keyed by a meeting's start, and marked with their model.**
The start is in the front matter and survives a rename; the file name does
not. The mark is the embedder's name, version and variant
(`SpeakerModels.embeddingSpace`): a later macOS that makes SpeakerKit pick
another variant makes vectors that mean something else, and two spaces are
never compared — those voices are simply not recognised until named again.
The store is one JSON file in Application Support, never the meetings
folder, which people sync. `VoiceMemory.defaultFile` is the real one even
from `swift run` and the tests' own process: every test passes a file of
its own.

**A summary model left loaded aborts the process at exit.** llama.cpp frees
its Metal device from a static destructor and asserts that nothing is
still allocated on it (`ggml_metal_rsets_free`, `[rsets->data count] == 0`):
quitting within two minutes of a summary was a SIGABRT and a crash report,
and so was every run of `CLIO_SUMMARIZE`, which calls `exit` with the model
it just used. `unloadSummaryModelsBeforeQuitting` frees them first — from
`applicationShouldTerminate`, and before `exit` in the tools. Reproduced
and fixed on the tool (exit 134, then 0, twice); the quit itself goes
through the same function and has not been watched. A plain unload is
enough: an autorelease pool and a pause were tried and were not needed.

**Kept audio belongs to the Markdown file.** Named after it, so
`MeetingMarkdown.write` moves it when a title changes the file's name and
`MeetingLibrary.trash` takes it to the Trash too. Only files named
`*.me.m4a` / `*.others.m4a` are ever deleted by the thirty-day sweep — a
recording of the user's own in the same folder is not Clio's to remove.
With the setting off nothing of the microphone is written anywhere, and
the microphone's side is silence while a dictation is being made, as it is
in the transcript. A meeting abandoned at quit keeps no audio.

**An import is a meeting with a fast clock.** `MeetingImport` drives a real
`MeetingSession` — the file as its system audio, a source that never
speaks as its microphone, `now` advanced by exactly the audio pushed — so
there is one path from audio to Markdown, not two. It pushes ten seconds
at a time and waits while more than two chunks are untranscribed: the
chunks waiting are audio in memory. The whole file is decoded into memory
first, as the diarizer will want it anyway.

**The MCP server speaks to this Mac and to nothing else.** Bound to
127.0.0.1 (`requiredLocalEndpoint`), so no other machine can connect; and
a request whose `Origin` is not this Mac is refused, so a page open in a
browser cannot have the browser ask for it — the check the protocol asks
of a local server. It answers `POST /mcp` with JSON and has no stream to
open: 405 for GET, 202 for a notification. Every tool reads; an id is a
file's name in the meetings folder and is refused if it is a path. Off by
default, because it is the one way anything Clio wrote is read by
something that is not Clio — the README's promise is worded for it.

**A line's time is a comment in the notes, not something beside them.**
`<!--12:40-->` at the end of the line it was written on. In the text, so
it survives every edit, undo and reload with the line it belongs to, and
is nothing at all in any other Markdown reader. `MarkdownStyle` never
shows the comment's own marks, on the caret's line or off it; the time
between them is drawn small. Stamped on Return, with when the line was
begun (`insertText` remembers), only while a meeting records. Taken out
wherever notes are read as words: the summary's prompt, the sidebar's
preview, Copy, the MCP tools.

**Every popup can be shown on request.** Settings ▸ About ▸ Developer —
the onboarding card at either step, the dictation pill through a whole
dictation, nothing heard and an error, and the three meeting cards — each
the real view, with nothing behind it (`AppCoordinator+Previews`,
`previewPill`). The section is in debug builds and in builds whose
`CFBundleVersion` is still 1, which is every `build-app.sh` build and no
release: `release.sh` stamps the commit count. A new popup belongs there
the day it is written; the ones that existed before it were only ever seen
by arranging a call.

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

**A list item's second line hangs under its first word.** `headIndent`
on the item's paragraph, as wide as the room its marker takes
(`MarkdownStyle`, `.listMarker`). And a to-do's leading "- " is not hidden
as other syntax is but set at a hundredth of a point and clear: with
nothing but null glyphs at its start, a paragraph's *first* line took the
head indent too, and every to-do moved in by its own hang.

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

**The intro card casts its own shadow; its window casts none.** The card
arrives scaling from 0.92 and fading in, and the window's shadow was taken
from it part-way: a smaller, greyer copy of the card stuck off one corner,
its edge a second outline inside the real one. `IntroSurface` draws the
shadow under the card and cut out of it, so it moves with the card, and
the window is `shadowMargin` larger all round to hold it. The same reason
the pill's panel has no shadow, met a second time. The meeting cards —
call detected, call starting, call ended — are done the same way
(`OfferSurface`), so every card has one hairline and one shadow.

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
- freeing a model gives the memory back (`ModelResidency`): large-v3 turbo
  adds 201 MB to the process and 42 MB of that stays behind; Qwen3 4B adds
  1.3 GB and 1 MB stays; a load after a free works, three seconds for turbo
- the summarizer on a scripted model: one request when the transcript fits,
  pieces then bullets when it does not, the notes leading the last prompt, a
  model's thinking cut out of the answer (`SummaryModelTests`); the catalog's
  summary models, their discovery, download and deletion, and models linked
  from elsewhere — a folder, a GGUF, Delete leaving the original (`ModelTests`)
- system audio through the process tap, on built-in speakers
  (`CLIO_SYSTEM_AUDIO_TEST`), and a whole meeting — both streams, the queue,
  WhisperKit, the Markdown and an Apple Intelligence summary
  (`CLIO_MEETING_TEST`, `say` through the speakers)
- an hour of meeting through a real session and the real model
  (`LongMeeting`): large-v3 turbo transcribes it in about two minutes, both
  sides, and resident memory goes from 55 MB to a 161 MB peak — under the
  test's limit, but not flat, and not yet explained
- the tap is allowed to hear, on this Mac with the permission granted:
  the probe's tone comes back in about half a second (`CLIO_SYSTEM_AUDIO_PROBE`)
- a summary by a downloaded model (`SummaryModelIntegration`, Qwen3 4B): a
  short meeting in 0.8 s in a 4k context under a 32k ceiling, a title from
  the summary, the user's own instructions followed in place of Clio's
- Settings ▸ Model as an 8 GB Mac lists it — Qwen3 4B recommended, Gemma 3
  12B dimmed with no download and the reason — and the summary's
  instructions open in Settings ▸ Meetings: looked at, not clicked
- the speaker models (`SpeakerIntegration`): downloaded through
  `ModelManager` (17 MB), loaded from Clio's folder with `download: false`,
  two of macOS's voices told apart turn by turn on the meeting's clock; and
  a whole call — a real session, Whisper, the models, Qwen3 4B — written
  out as Me / Daniel / Karen: one said her name, one was asked by name and
  answered; with the two invited, as Daniel Lee and Karen Holt, and a third
  invitee who never spoke given to nobody. No audio left behind
- a voice named in three meetings is recognised in a fourth, from other
  words, and the other voice is not taken for it (`SpeakerIntegration`,
  `voicesAcrossMeetings`) — on the real models, with synthetic voices
- a recording of two voices, imported through Whisper, the speaker models
  and Gemma 3 12B: 34 s in 8 s, both named from how they greet each other,
  summarized (`SpeakerIntegration`, `anImportedRecording`)
- Gemma 3 12B writes summaries (`SummaryModelIntegration`): 2.7 s for a
  short meeting, a title, the user's instructions followed, and a point
  that is only in the notes ("where do we park monday?") given a heading
  of its own
- the MCP server over real HTTP on the loopback address (`MCPTests`): a
  question answered, a page elsewhere refused, only `POST /mcp` heard
- a meeting's vocabulary as Whisper's prompt does not empty the transcript
  (`SanitizerIntegration`)
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
  does for a tap with nothing playing; not seen. The probe's "refused" rests
  on the same assumption: turn System Audio Recording off for Clio and run
  `CLIO_SYSTEM_AUDIO_PROBE` — it should say refused. Nobody has listened
  for the tone either; it is meant to be inaudible at any volume.
- **the held-microphone rule against a real call app.** A call is offered
  after two checks on the microphone; that Zoom or Teams opening it for a
  moment at launch is what the first check lands on is the reason, not
  something watched.
- **voices on a real call.** Everything above is synthetic voices, clean
  and far apart (0.85 and more between them). People on one call, on one
  codec, some of them on a speakerphone in one room, are the real test and
  nobody has run it. Two people in one line of transcript go to whoever
  spoke longer.
- **recognising a real person.** The thresholds are borrowed and the only
  voices tried are synthetic. Whether a colleague on AirPods one day and a
  laptop the next is one voice, and whether two colleagues are two, is
  what `CLIO_VOICEPRINT_REPORT` is for once there are named meetings.
- **short meetings split a voice.** Two five-second turns by one voice
  came back as two speakers, 0.52 apart: too far to merge without merging
  different people. Seen once, in a 22-second test call; not on longer ones.
- **the voice controls in Settings ▸ Model ▸ Speakers**, and trashing a
  meeting taking its voices: written, tested underneath (`VoiceMemory`),
  not clicked.
- **naming a voice, by clicking.** The transcript with one voice named and
  one a number, and the Speakers row in Settings ▸ Model, have been looked
  at (`CLIO_MEETING_PANE=transcript CLIO_LIBRARY_SHOW=1`). The popover a
  click on a name opens has not: nothing here can click it.
- **a summary after a voice is renamed.** It still says the old name;
  Summarize Again fixes it, and nothing does it for you.
- **Gemma 3 12B's memory.** It writes summaries (above); what its context
  really costs has not been measured — the ceiling for it is an estimate
  scaled from Qwen3 4B, which is no longer installed on the Mac this is
  developed on.
- **an MCP client.** The server is tested with URLSession. No app that
  speaks the protocol — Claude, LM Studio — has been pointed at it, and
  the Settings toggle has not been turned on in the app.
- **`clio://` links.** Parsed and built in tests; the scheme is in the
  Info.plist, and nothing has been opened with `open clio://…` — it needs
  an installed build.
- **the card when a calendar call starts, and the countdown before a
  meeting stops itself.** Decided in tests (`CallWatch.starting`); neither
  has been seen, and the countdown changes what happened before: the
  meeting stopped at once.
- **the Homebrew cask.** `Casks/clio.rb`, written and syntax-checked; not
  run through `brew audit`, and nobody has run `brew tap petit-software/clio
  https://github.com/petit-software/clio` against it — it is not on `main`
  yet.
- **a note's time, written in a real meeting.** The editing check stamps
  lines and finds a click; nobody has typed notes during a recording and
  then clicked a time to hear it.
- **playing kept audio.** The control and the clickable times are on the
  page (`CLIO_MEETING_PANE=transcript CLIO_LIBRARY_SHOW=1`); nobody has
  pressed Play, heard both sides in step, or clicked a time. The files
  are written and are the right length (`MeetingTests`, keepsAudio).
- **an import from the app.** The importer is proven underneath; the menu
  item, the drop on the window, the progress row in the sidebar and
  Stop Importing have not been used.
- **the thirty-day sweep on real files**, and audio kept across a real
  meeting with a real microphone.
- **an 8 GB Mac.** The speech model is freed before a downloaded summary
  model loads there (`makeRoomForSummary`), and the ceiling is 8k; both are
  decisions tested on numbers, on a 64 GB machine.
- **the summary's instructions, typed into.** The editor opens and shows
  Clio's own; nobody has typed in it, pressed Reset, or run a summary from
  the app with changed ones — only through the test.
- **a meeting renamed by the model, in the app.** The session renames the
  record and its file (`MeetingTests`); the library window following a file
  that changes name under it at the end of a meeting has not been watched.
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
  "Push to talk with a three-key chord ends when any one key is let go" is
  its sibling and fails the same way, less often.
