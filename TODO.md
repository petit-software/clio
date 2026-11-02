# To do

Meeting notes landed in `meeting-notes`. What is left, in order.

## Gaps in meetings

- [x] **Offer card clicks.** Accepts first mouse and may become key — the
      documented fix. Proving a first click needs a real one; see below.
- [x] **Output format change mid-call.** The tap's aggregate is clocked by the
      output device. AirPods going into call mode change that device's format
      without changing the device; rebuild the capture when they do.
- [x] **Title edits saved on close**, not only on Return or Stop.
- [x] **`MeetingSession` tests.** Injectable audio sources; cover stop-and-drain,
      wall-clock gaps, and the microphone muted while dictating.
- [x] **Quitting mid-meeting** finishes the chunks in flight (bounded wait)
      instead of dropping them.

## Library window

- [x] **Read meetings back.** A parser for the Markdown Clio writes; round-trip
      tests.
- [x] **The library.** Every meeting in the folder, watched for changes made
      outside Clio, searchable.
- [x] **The window.** Sidebar — the live meeting, then Today / Yesterday /
      Earlier, then Dictations — and the meeting as a document: title, date,
      people, Notes / Summary / Transcript.
- [x] **Edit and manage saved meetings.** Title and notes write back to the
      file; Show in Finder; Move to Trash.
- [x] **The live meeting lives here.** Replaces the separate meeting window;
      Take Notes from the sidebar.
- [x] **Dictations** in the sidebar: whatever Settings ▸ history keeps (last 20,
      on disk only if asked). The privacy default is not changed.
- [x] **A Dock icon while the window is open**; "Open Clio" in the menu.
- [x] **A tool to see it**: `CLIO_LIBRARY_SHOW` on a sample folder.

## Finish

- [x] AGENTS.md, README, tests, `build-app.sh`, commit.

## Needs a person

- [ ] A real Zoom / Meet / Teams call: the offer (click it once — a first
      click cannot be proven from inside the app), auto-stop, echo with real
      speech.
- [ ] AirPods as microphone and output during a call (ask before opening them).
- [ ] Granting the calendar and seeing a real event name a meeting; refusing
      system audio and seeing the warning.
- [ ] An hour-long meeting: memory, and whether transcription keeps up.
- [ ] Release 1.0: merge, `release.sh`, appcast, GitHub release.
