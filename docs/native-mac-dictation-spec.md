# Whisperbar — Native macOS Dictation App

*A Swift/SwiftUI rewrite of the Handy concept: press a key, speak, get text pasted into whatever app you're in. Fully offline, local models only.*

Working codename: **Whisperbar**. (Handy's MIT license covers its code, not its name, logo, or icon — pick your own branding.)

---

## 1. Product definition

**The loop:**

1. User holds (or taps) a global hotkey.
2. A small non-focusing overlay appears showing a live level meter.
3. Mic audio is captured at 16 kHz mono.
4. On release (or second tap), silence is trimmed via VAD.
5. A locally downloaded Whisper model transcribes the audio.
6. Text is pasted into the frontmost app's focused text field.

**Non-goals for v1:** cloud fallback, real-time streaming transcription, LLM post-processing, multi-platform, iOS companion.

**Success criteria:**

- End-to-end latency under 1.5 s for a 5-second utterance on an M-series Mac with a warm model.
- Zero network traffic after models are downloaded.
- Never steals focus from the app the user was typing in.
- Idle CPU under 1%, idle memory under 150 MB with a small model resident.

---

## 2. What Handy does and how we diverge

| Concern | Handy | Whisperbar |
|---|---|---|
| Shell | Tauri (Rust + WebView) | Native SwiftUI, no webview |
| Audio I/O | `cpal` | `AVAudioEngine` |
| VAD | `vad-rs` + Silero ONNX | Silero ONNX via onnxruntime-swift |
| ASR | whisper.cpp (GGML) / Parakeet | WhisperKit (CoreML + ANE), whisper.cpp as fallback engine |
| Hotkeys | `rdev` | `CGEventTap` + `NSEvent` monitors |
| Text output | enigo / clipboard paste | `NSPasteboard` + synthesized ⌘V |
| Settings UI | React + Tailwind | SwiftUI `Settings` scene |
| Binary size | ~90 MB+ | ~15–25 MB before models |

The big win of going native is the Apple Neural Engine. WhisperKit runs the encoder on ANE, which is typically 2–4× faster and dramatically lower power than Metal-only GGML inference on the same machine.

---

## 3. Technical stack

- **Language:** Swift 6, strict concurrency on.
- **Minimum OS:** macOS 14 Sonoma. (macOS 13 is possible but you lose `@Observable` and some `MenuBarExtra` fixes.)
- **UI:** SwiftUI, `MenuBarExtra` for the status item, `Settings` scene for preferences, `LSUIElement = YES` so no Dock icon.
- **ASR:** [WhisperKit](https://github.com/argmaxinc/WhisperKit) via SPM. Handles CoreML model compilation, Hugging Face downloads, and word timestamps.
- **VAD:** `onnxruntime-swift-package-manager` running `silero_vad.onnx` (~2 MB, bundle it in the app).
- **Updates:** Sparkle 2 with an EdDSA-signed appcast.
- **Distribution:** Developer ID signed, hardened runtime, notarized, shipped as a DMG. **Not App Store eligible** — see §9.

---

## 4. Architecture

```
WhisperbarApp (SwiftUI @main)
├── AppCoordinator            state machine, wires everything
├── HotkeyManager             CGEventTap, push-to-talk & toggle
├── PermissionsCoordinator    mic + Accessibility, onboarding flow
├── AudioRecorder             AVAudioEngine tap → 16 kHz Float32 buffer
├── VADProcessor              Silero ONNX, trims lead/trail silence
├── TranscriptionEngine       protocol
│   ├── WhisperKitEngine      primary
│   └── WhisperCppEngine      optional fallback for GGML models
├── ModelManager              catalog, download, verify, delete, discover
├── TextInjector              paste / type into frontmost app
├── OverlayController         non-activating NSPanel + waveform
├── FeedbackPlayer            start/stop/cancel sounds
├── HistoryStore              last N transcripts, in-memory + optional disk
└── SettingsStore             Codable JSON, @Observable
```

### State machine

```
idle ──hotkey down──▶ recording ──hotkey up──▶ transcribing ──▶ injecting ──▶ idle
  ▲                       │                        │               │
  └────────── Esc ────────┴──────── Esc ───────────┘───────────────┘
```

Every state is cancellable. Cancel restores the clipboard, hides the overlay, and plays the cancel sound. Recording auto-stops at a configurable max duration (default 120 s) to avoid runaway captures.

---

## 5. Module specs

### 5.1 HotkeyManager

The riskiest module — prototype this first. Requirements:

- Detect key **down and up** separately (push-to-talk needs both). `RegisterEventHotKey` from Carbon only gives you press, so you need a `CGEventTap` at `.cgSessionEventTap` with `.listenOnly` for keyDown/keyUp/flagsChanged.
- Support modifier-only chords (e.g. hold both ⌥ keys) via `flagsChanged`.
- Push-to-talk needs a short **hold threshold** (~200 ms) so an accidental tap doesn't fire a 40 ms recording.
- Toggle mode: first press starts, second stops.
- Watch for tap disable events (`tapDisabledByTimeout`) and re-enable — macOS will kill a slow tap.
- Esc always cancels while recording, regardless of the configured hotkey.

A reference implementation is in `HotkeyManager.swift` alongside this spec.

**Warning:** shortcuts containing `fn` (Globe) only fire on Apple keyboards. `fn` is a vendor-specific HID usage that macOS surfaces only for Apple devices; third-party keyboards handle it in firmware and send nothing. Don't make it a default; show a warning if a user picks it.

### 5.2 AudioRecorder

```swift
let engine = AVAudioEngine()
let input = engine.inputNode
let hwFormat = input.outputFormat(forBus: 0)
let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                           sampleRate: 16_000,
                           channels: 1,
                           interleaved: false)!
let converter = AVAudioConverter(from: hwFormat, to: target)!
input.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { buf, _ in
    // convert → append to ring buffer → publish RMS for the meter
}
```

- Preallocate a ring buffer sized for the max recording duration; never allocate inside the tap callback.
- Publish RMS at ~30 Hz on the main actor for the overlay waveform; throttle it, don't fire per buffer.
- Handle device changes mid-session (`AVAudioEngineConfigurationChange`) by restarting the engine.
- Respect the user's chosen input device by setting the `AudioDeviceID` on the engine's input `AUHAL` unit.

### 5.3 VADProcessor

Silero VAD in 30 ms frames, returning speech probability per frame. Use it to:

- Trim leading and trailing silence before transcription (big latency win — Whisper pads to 30 s chunks internally).
- Optionally abort if the whole clip is below the speech threshold ("nothing heard").

If you want to ship v1 sooner, start with a plain RMS energy gate and add Silero in the polish milestone. The quality delta only really shows up in noisy rooms.

### 5.4 TranscriptionEngine

```swift
protocol TranscriptionEngine: AnyObject {
    var isLoaded: Bool { get }
    func load(model: InstalledModel) async throws
    func unload() async
    func transcribe(samples: [Float], options: TranscribeOptions) async throws -> Transcript
}

struct TranscribeOptions {
    var language: String?      // nil = auto-detect
    var translateToEnglish: Bool
    var initialPrompt: String? // seed with custom vocabulary
}
```

**Keep the model warm.** Cold-loading a large CoreML model is 3–8 s. Strategy:

- Begin `load()` on hotkey-**down**, in parallel with recording, so it's ready by the time the user stops talking.
- Optional setting: "Keep model in memory" (default on for models under 1 GB).
- Unload after N minutes of inactivity if the setting is off.

Feed the `initialPrompt` with the user's custom vocabulary list — this is the cheapest way to make Whisper spell names and jargon correctly.

### 5.5 ModelManager

- Ship a `models.json` catalog (bundled, optionally refreshed from your CDN) with: id, display name, HF repo, size, quality tier, languages, SHA-256.
- Download with `URLSession` background configuration so it survives app restarts; show byte progress and allow cancel/resume.
- Store under `~/Library/Application Support/<bundle-id>/models/`.
- Verify checksum before marking installed; delete partials on failure.
- **Auto-discover** models the user dropped in manually, and read the shared HF cache at `~/.cache/huggingface/hub` so a model another tool already downloaded is reused.
- Expose the models directory path in an About/Debug pane, plus a "Reveal in Finder" button — invaluable for support.

Suggested v1 catalog:

| Model | Size | Use case |
|---|---|---|
| `distil-whisper_distil-large-v3` | ~600 MB | Default. English, fast, accurate |
| `openai_whisper-small` | ~250 MB | Low-RAM machines, multilingual |
| `openai_whisper-large-v3-turbo` | ~800 MB | Best quality, multilingual |

### 5.6 TextInjector

```
1. Capture current NSPasteboard contents (all types) + changeCount
2. Write transcript to pasteboard
3. Synthesize ⌘V via CGEvent at .cgAnnotatedSessionEventTap
4. Wait ~150 ms, then restore original pasteboard if changeCount is what we set
```

Details that matter:

- Post the key events with the correct `flags` on **both** keyDown and keyUp, or some apps swallow it.
- Detect **secure input** (`IsSecureEventInputEnabled()`) — password fields and some terminals block synthetic events entirely. Degrade to clipboard-only plus a notification saying the text was copied.
- Direct-typing fallback: `CGEvent.keyboardSetUnicodeString` per character with ~2 ms spacing. Slower and drops characters in some Electron apps, but works where paste doesn't.
- Post-processing toggles: trim trailing period, capitalize first letter, and apply the user's find/replace dictionary before injection.

### 5.7 OverlayController

A borderless `NSPanel`:

```swift
panel.styleMask = [.borderless, .nonactivatingPanel]
panel.level = .statusBar
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
panel.isFloatingPanel = true
panel.ignoresMouseEvents = true
panel.hasShadow = true
```

`.nonactivatingPanel` is **mandatory**. If the overlay takes focus, the frontmost app changes and the paste lands in the wrong place — this was Handy's most-reported bug class. Test paste-back with Terminal, Safari, Slack, and a full-screen app before calling it done.

Positions: None / Top center / Bottom center / Near cursor. Content: a pill with a live waveform while recording, a spinner while transcribing.

---

## 6. Settings — the necessary minimum

**General**
- Hotkey recorder
- Mode: Push-to-talk / Toggle
- Launch at login (`SMAppService.mainApp.register()`)
- Show icon in menu bar

**Model**
- Installed + available list, size, download / delete, progress
- Active model selector
- Keep model in memory (toggle)

**Audio**
- Input device (+ "System default")
- Live input level meter
- Voice activity detection on/off + sensitivity
- Max recording length

**Transcription**
- Language: Auto / specific
- Translate to English
- Custom vocabulary (one term per line → fed as initial prompt)
- Word replacements (find → replace list)

**Output**
- Paste automatically / Copy only
- Method: Paste (⌘V) / Type characters
- Trim trailing punctuation
- Capitalize first letter

**Feedback**
- Overlay position: None / Top / Bottom / Near cursor
- Play sound on start, stop, cancel

**About / Debug**
- Version, model directory path, "Reveal in Finder"
- Permission status with re-request buttons
- Copy diagnostic log

Persist as a single `Codable` struct written to `~/Library/Application Support/<bundle-id>/settings.json`, not scattered `UserDefaults` keys. Handy explicitly lists "settings have become bloated and messy" as tech debt — start with one typed struct and a migration version field.

---

## 7. Permissions & onboarding

Two permissions, requested in order, with a dedicated onboarding window:

1. **Microphone** — `NSMicrophoneUsageDescription` in Info.plist, `AVCaptureDevice.requestAccess(for: .audio)`. Prompts inline.
2. **Accessibility** — `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])`. Needed for both the event tap and posting ⌘V. Cannot be granted programmatically; deep-link to `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility` and poll `AXIsProcessTrusted()` until granted.

Show a persistent, non-nagging banner in Settings if either is missing. On macOS, revoking Accessibility while running silently kills the event tap — poll trust state every few seconds and re-install the tap when it returns.

---

## 8. Build milestones

| # | Milestone | Deliverable | Est. |
|---|---|---|---|
| 0 | Skeleton | Menu bar app, Settings window, onboarding, permission checks | 1 day |
| 1 | Capture | Hotkey down/up → record → WAV on disk. Push-to-talk and toggle both working | 2 days |
| 2 | ASR | WhisperKit wired in, transcript printed to console, warm-load strategy | 2 days |
| 3 | Injection | Paste into frontmost app with clipboard restore; secure-input fallback | 1 day |
| 4 | Models | Catalog, download UI, verify, delete, auto-discovery | 2 days |
| 5 | Polish | Overlay, sounds, VAD, full settings UI, history | 3 days |
| 6 | Ship | Signing, hardened runtime, notarization, Sparkle appcast, DMG, icon | 2 days |

Roughly two focused weeks to a daily driver. Milestone 1 is where the unknowns are — build it before committing to the rest.

---

## 9. Known hazards

- **Not App Store distributable.** Posting `CGEvent`s and running a session-level event tap are incompatible with the App Sandbox. Direct download + Sparkle only.
- **`fn` / Globe key** only works on Apple keyboards. Hardware limitation, not fixable.
- **Bluetooth headset mics** force the device into bidirectional SCO mode, degrading playback while recording. Warn in the device picker and suggest keeping the headset as output while using the built-in mic as input.
- **Overlay focus theft** breaks paste-back. See §5.7.
- **Secure input** blocks synthetic events; detect and degrade.
- **Cold model load** dominates perceived latency. Preload on hotkey-down.
- **Event tap timeouts** — macOS disables slow taps. Never do work in the tap callback; hand off to a serial queue immediately.
- **Sleep/wake** invalidates `AVAudioEngine`; observe `NSWorkspace.didWakeNotification` and rebuild.

---

## 10. Nice-to-haves for v2

- CLI flags for remote control (`--toggle`, `--cancel`) via a single-instance URL scheme, so Raycast/Alfred/Keyboard Maestro can drive it.
- Transcript history window with search and re-copy.
- Per-app profiles (different vocabulary in your code editor vs. Mail).
- Optional local LLM post-processing pass for punctuation and tone cleanup.
- Parakeet or an MLX-based engine as an alternative backend behind the existing protocol.
