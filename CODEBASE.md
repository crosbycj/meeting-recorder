# Meeting Recorder — Codebase Documentation

A macOS menu bar application that records meetings (system audio + microphone), transcribes them locally using FluidAudio/Parakeet, and generates summaries via the Anthropic Claude API. No main window, no Dock icon (`LSUIElement = YES`). Built with AppKit, not SwiftUI.

- **Bundle ID:** `com.example.MeetingRecorder`
- **Deployment target:** macOS 14.2+
- **Xcode:** 16.0+
- **Sandbox:** Disabled (required for ScreenCaptureKit)
- **External dependency:** FluidAudio 0.7.9+ (SPM, `https://github.com/FluidInference/FluidAudio.git`)

---

## 1. File Inventory

### Source Files (3,620 lines total)

| File | Lines | Type | Description |
|------|-------|------|-------------|
| `main.swift` | 6 | Entry point | Creates `NSApplication`, sets `AppDelegate`, calls `app.run()`. No `@main` attribute. |
| `AppDelegate.swift` | 95 | `final class AppDelegate: NSObject, NSApplicationDelegate` | App lifecycle. Owns `RecordingStorage`, `TranscriptionManager`, `SummaryManager`, `MenuManager`. Requests screen capture access at launch. Handles graceful termination with active recording. |
| `MenuManager.swift` | 1381 | `@MainActor final class MenuManager: NSObject, NSMenuDelegate` | Owns the `NSStatusItem`, builds the entire menu, handles all user actions. Includes diagnostics submenu, audio source failure alerts, recording status suffixes, retry actions, auto-retry of no_api_key recordings, and storage snapshot computation. |
| `AudioRecorder.swift` | 223 | `actor AudioRecorder` | Orchestrates a single recording session. Creates the recording directory, starts `SystemAudioCapture` + `MicCapture`, stops them, mixes via `AudioMixer`, writes metadata. Tracks which audio sources are enabled. |
| `SystemAudioCapture.swift` | 307 | `final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate` | Captures system audio via ScreenCaptureKit. Writes PCM samples to a `.caf` file using `AVAssetWriter`. Not an actor; uses manual `DispatchQueue`-based synchronization. |
| `MicCapture.swift` | 115 | `final class MicCapture` | Captures microphone audio via `AVAudioEngine` input tap. Writes to a `.caf` file using `AVAudioFile`. Not an actor; uses `NSLock` for file access. |
| `AudioMixer.swift` | 147 | `final class AudioMixer` | Post-recording mixer. Takes system audio + mic audio temp files, composites them into a single `.m4a` using `AVMutableComposition` + `AVAssetExportSession`. |
| `TranscriptionManager.swift` | 355 | `actor TranscriptionManager` | Manages model download/load, transcription queue, startup reconciliation, and triggers summary generation after successful transcription. |
| `SummaryManager.swift` | 352 | `actor SummaryManager` | Handles API key storage (Keychain), Claude API calls for summary generation, title generation, and the API key prompt dialog. |
| `RecordingStorage.swift` | 485 | `actor RecordingStorage` + `struct RecordingInfo` | File system operations for `~/MeetingRecorder/recordings/`. Creates directories, reads/writes `metadata.json`, saves transcript and summary files, lists recordings, renames folders. `RecordingInfo` is the public-facing recording data model. |
| `RecordingState.swift` | 19 | `struct RecordingState: Sendable` | Value type holding all state for an active recording: title, attendees, start time, directory URL, temp file URLs, enabled audio sources (`systemAudioEnabled`, `micAudioEnabled`). |
| `Models/CalendarEvent.swift` | 12 | `struct CalendarEvent` | Value type for a calendar event: title, start/end date, attendees. |
| `Models/TranscriptionResult.swift` | 15 | `struct TranscriptionResult: Sendable` | Value type for transcription output: text, word timings, confidence, audio duration, processing time. |
| `CalendarManager.swift` | 108 | `final class CalendarManager` | Wraps `EKEventStore`. Requests calendar access, fetches today's events (non-all-day, not yet ended), observes `EKEventStoreChanged` notifications. |

### Configuration Files

| File | Description |
|------|-------------|
| `Info.plist` | Sets `LSUIElement = YES`, declares usage descriptions for Calendar (full access) and Microphone. |
| `AGENTS.md` | Architecture decision log: deployment target, capture strategy, transcription library, pipeline order, storage format. |

### Models Directory

`MeetingRecorder/Models/` contains two plain value types: `CalendarEvent.swift` and `TranscriptionResult.swift`.

---

## 2. Architecture Overview

### Component Graph

```
AppDelegate
 ├── RecordingStorage (actor) ─── shared by all components
 ├── TranscriptionManager (actor)
 │    └── references SummaryManager, RecordingStorage
 ├── SummaryManager (actor)
 │    └── references RecordingStorage
 └── MenuManager (@MainActor)
      ├── AudioRecorder (actor)
      │    ├── SystemAudioCapture (class, DispatchQueue-synced)
      │    ├── MicCapture (class, NSLock-synced)
      │    ├── AudioMixer (class)
      │    └── references RecordingStorage
      ├── CalendarManager (class, main thread)
      ├── references TranscriptionManager
      ├── references SummaryManager
      └── references RecordingStorage
```

### Ownership and Initialization

`AppDelegate` creates four top-level objects:

1. `RecordingStorage()` — created eagerly as a stored property.
2. `TranscriptionManager(recordingStorage:)` — created lazily.
3. `SummaryManager(recordingStorage:)` — created lazily.
4. `MenuManager(transcriptionManager:, summaryManager:, recordingStorage:)` — created lazily, `@MainActor`.

`MenuManager` internally creates:

- `AudioRecorder(storage:)` — its own instance of the audio recording actor.
- `CalendarManager()` — its own instance of the calendar wrapper.

### Threading Model

| Component | Isolation | Notes |
|-----------|-----------|-------|
| `MenuManager` | `@MainActor` | All UI work. NSMenu building, status item updates, timer callbacks. |
| `AudioRecorder` | `actor` | Recording lifecycle. Calls into `SystemAudioCapture` and `MicCapture` from actor context. |
| `RecordingStorage` | `actor` | All file I/O serialized through actor. `rootURL` and `recordingsRootURL` are `nonisolated`. |
| `TranscriptionManager` | `actor` | Model download, transcription queue, startup reconciliation. |
| `SummaryManager` | `actor` | API calls, keychain access, summary parsing. `promptForApiKey()` is `@MainActor static`. |
| `SystemAudioCapture` | Not an actor | Uses two `DispatchQueue`s: `sampleQueue` (SCStream output handler) and `stateQueue` (guards writer and running state). |
| `MicCapture` | Not an actor | Uses `NSLock` to guard `audioFile` writes from the `AVAudioEngine` tap callback. |
| `AudioMixer` | Not an actor | Stateless; called within `AudioRecorder`'s actor context. |
| `CalendarManager` | Not an actor | Called from `@MainActor` context (MenuManager). Uses `EKEventStore` on main thread. |

### Cross-Actor Communication Pattern

Actors expose a `setOnStateChanged` / `setOnRecordingStateChanged` method that accepts a `@MainActor @Sendable` closure. When internal state changes, the actor calls `notifyStateChanged`, which dispatches to `@MainActor` via `Task { @MainActor in ... }`.

This pattern is used by:

- `AudioRecorder.setOnRecordingStateChanged` → notifies `MenuManager` of recording start/stop (passes `RecordingState?`).
- `TranscriptionManager.setOnStateChanged` → notifies `MenuManager` of transcription state (downloading, transcribing, progress, ready, error).
- `SummaryManager.setOnStateChanged` → notifies `MenuManager` of summary state (generating, completed, error, noApiKey).

`MenuManager` registers all three callbacks in `configure()`. Each callback updates local `@MainActor` state and calls `rebuildMenu()`.

### Dependency Injection

Components receive `RecordingStorage` via constructor injection. `TranscriptionManager` receives `SummaryManager` via `setSummaryManager(_:)` called in `applicationDidFinishLaunching`. `AudioRecorder` also accepts `AudioMixer` and `FileManager` in its initializer (defaulting to new instances).

---

## 3. Data Flow

### Full Pipeline: Start Recording → Summary in Menu

#### Phase 1: Start Recording

1. User clicks "New Recording" or "Start Recording" in an event submenu.
2. `MenuManager` calls `beginStartRecording(eventTitle:attendees:startTime:associatedEventStartTime:calendarEvent:)`.
3. Sets `recordingActionInFlight = true`, calls `rebuildMenu()` (shows "Starting..." state).
4. Calls `await audioRecorder.startRecording(...)` inside a `Task`.
5. `AudioRecorder.startRecording`:
   a. Guards against double-start (`activeRecordingState == nil`).
   b. Calls `storage.createRecordingDirectory(eventTitle:startTime:)` → creates `~/MeetingRecorder/recordings/YYYY-MM-DD_HHmm_slug/`.
   c. Computes temp file URLs: `system-audio-temp.caf` and `mic-audio-temp.caf` within the directory.
   d. Creates `SystemAudioCapture(outputURL:)` and `MicCapture(outputURL:)`.
   e. Starts system audio capture — may fail (permission denied, no display). Logs and continues.
   f. Starts mic capture — may fail (permission denied, no mic). Logs and continues.
   g. If **both** fail, removes the directory and throws `noAudioSourcesAvailable`.
   h. If at least one succeeds, sets `activeRecordingState` with `systemAudioEnabled` / `micAudioEnabled` flags (triggers `didSet` → `notifyRecordingStateChanged`).
6. Back in `MenuManager`, after `startRecording` returns, calls `showSourceFailureAlertIfNeeded(for:)` — shows an `NSAlert` if one audio source failed (see Audio Source Failure Alerts below).
7. If both sources failed, `showBothSourcesFailedAlert()` is shown instead.
8. `MenuManager` receives the recording state callback → sets `currentRecordingState`, calls `updateStatusItemButtonAppearance()` (shows `record.circle` icon + "Recording" text in menu bar), `rebuildMenu()` (shows stop button + optional audio source warning), `configureRecordingTimerIfNeeded()` (starts 1-second timer to update elapsed time).

#### Phase 2: During Recording

- `SystemAudioCapture` receives `CMSampleBuffer` callbacks on its `sampleQueue`. Writes audio samples to `system-audio-temp.caf` via `AVAssetWriter`.
- `MicCapture` receives `AVAudioPCMBuffer` callbacks from `AVAudioEngine` tap. Writes to `mic-audio-temp.caf` via `AVAudioFile`.
- If the menu is open, `MenuManager.recordingTimer` fires every second, updating the stop button title with elapsed time (`"Stop Recording · M:SS"`).
- If only one audio source is active, a warning item appears below the stop button (e.g., "Microphone only — system audio not available" with `exclamationmark.triangle` icon).
- The status bar button shows the `record.circle` SF Symbol (template image) with "Recording" text. Falls back to text-only if the symbol is unavailable.

#### Phase 3: Stop Recording

1. User clicks "Stop Recording · M:SS".
2. `MenuManager.stopRecordingTapped` sets `recordingActionInFlight = true`, calls `rebuildMenu()` (shows "Stopping...").
3. Calls `await audioRecorder.stopRecording()` inside a `Task`.
4. `AudioRecorder.stopRecording`:
   a. Captures current `RecordingState` and source references.
   b. Stops `SystemAudioCapture` — calls `stream.stopCapture()`, removes stream output, finalizes `AVAssetWriter`. If stop fails, sets `mixSystemAudioURL = nil` so mixer skips it.
   c. Stops `MicCapture` — removes tap, stops engine, nils the `AVAudioFile`.
   d. Calls `mixer.mix(systemAudioURL:micAudioURL:outputURL:)` → creates `recording.m4a` in the directory.
   e. Computes audio duration from the output file.
   f. Calls `storage.writeMetadata(...)` → writes `metadata.json`.
   g. Defers: removes temp `.caf` files, calls `cleanupState()` (nils captures, sets `activeRecordingState = nil`).
   h. Returns the directory URL.
5. `MenuManager` receives the directory URL. Calls `recordingStorage.renameDirectoryUsingStoredTitle(directoryURL:)` — this is a no-op at this point because no generated title exists yet.
6. Sets `recordingActionInFlight = false`, marks storage snapshot stale, updates UI, calls `refreshRecentRecordings(force: true)`.
7. Fires off `transcriptionManager.transcribe(directoryURL:)` in a detached `Task`.

#### Phase 4: Transcription

1. `TranscriptionManager.transcribe(directoryURL:)`:
   - If state is `.ready`, enqueues and drains.
   - If model isn't loaded yet (`.idle`, `.downloadingModel`, `.loadingModel`), enqueues only. Transcription will happen after `preloadModel` completes and calls `drainQueueIfNeeded`.
   - If `.error`, enqueues and retries model load once (1.5s delay).
   - If `.transcribing`, enqueues only (will drain when current finishes).
2. `enqueueForTranscription` adds the URL to `queuedDirectoryURLs`, updates metadata status to `"pending"`.
3. `drainQueueIfNeeded` processes queued URLs sequentially (one at a time, FIFO).
4. `beginTranscription(directoryURL:)`:
   a. Sets state to `.transcribing(directoryURL, progress: 0)`.
   b. Updates metadata status to `"transcribing"`.
   c. Starts a progress observation task that reads `asrManager.transcriptionProgressStream` and updates progress.
   d. Calls `asrManager.transcribe(audioFileURL, source: .system)` — this is the FluidAudio ASR call on the `.m4a` file.
   e. On success: maps `AsrResult` to `TranscriptionResult`, saves `transcript.txt` (with metadata header), updates metadata status to `"completed"`.
   f. On failure: updates metadata status to `"failed"`.
   g. Sets state back to `.ready` (triggering queue drain for next item).

#### Phase 5: Summary Generation

1. After successful transcription, `TranscriptionManager` reads `recordingInfo` for the directory to get `summaryPromptTitle`.
2. Fires `summaryManager.generateSummary(directoryURL:transcript:meetingTitle:)` in a detached `Task`.
3. `SummaryManager.generateSummary`:
   a. Checks for API key. If missing, sets state to `.noApiKey`, updates metadata to `"no_api_key"`, returns.
   b. Sets state to `.generating(directoryURL)`.
   c. Calls `callClaudeAPI(apiKey:transcript:meetingTitle:)`.
   d. API call details:
      - Endpoint: `POST https://api.anthropic.com/v1/messages`
      - Model: `claude-haiku-4-5`
      - Max tokens: 220
      - System prompt instructs JSON response: `{"title":"...","summary":"..."}`
      - If transcript > 80,000 chars, truncates to first 40k + last 40k with `[transcript truncated]` marker.
      - If meeting title exists, prepends `"Meeting title: ..."` to user content.
   e. Parses response: tries JSON decode, falls back to code-fence stripping, falls back to brace extraction, falls back to treating whole response as summary.
   f. If no meeting title was provided and Claude returned a `generatedTitle`, calls `recordingStorage.applyGeneratedTitle(directoryURL:generatedTitle:)` — this updates metadata and renames the folder.
   g. Saves `summary.txt`, updates metadata status to `"completed"`.
   h. Also updates `transcript.txt` by inserting a `"Summary: ..."` line before the first blank line in the header.
   i. Sets state to `.completed(directoryURL)`.
4. `MenuManager` receives `.completed` state change → `refreshRecentRecordings(force: true)` → `rebuildMenu()`. The recording now shows with a summary in its submenu.

#### Phase 6: Result Visible in Menu

When the menu is opened:
- `menuWillOpen` calls `refreshRecentRecordings(force: true)` which loads recordings from `RecordingStorage.listRecentRecordings(days: 7)`.
- Each `RecordingInfo` includes `summary` (read from `summary.txt` if `summaryStatus == "completed"`).
- `buildRecordingSubmenu` shows a view-based `RecordingSummaryMenuItemView` if summary text exists.
- Recording row titles include status suffixes (e.g., " — Transcribing…", " — Failed", " — No API Key").

---

## 4. Menu Structure

### Status Bar Item

`NSStatusItem` with `variableLength`. Created in `setupStatusItem()`.

**When not recording:**
- Image: SF Symbol `waveform` (template image, `imageLeading` position).
- Title: next upcoming calendar event as `"h:mm a EventTitle"`, truncated to 30 chars. Empty string if no calendar access or no upcoming events.
- If no upcoming event text, `imagePosition` is `.imageOnly` (icon only, no title text).
- Updated every 60 seconds by `statusTextTimer` and on calendar change notifications.

**When recording:**
- Image: SF Symbol `record.circle` (template image). Falls back to `nil` if unavailable.
- Title: `"Recording"`.
- `imagePosition`: `.imageLeading` if image loaded, `.noImage` if not.
- Tooltip: `"Meeting Recorder: Recording"`.

### Status Item Button Configuration Retry

`configureStatusItemButtonWithRetry()` handles the rare case where `statusItem.button` is nil immediately after creation. It retries up to 10 times with 0.1s delays. If all retries fail, it removes the old status item and recreates it from scratch via `setupStatusItem()`.

### Menu Layout (Top to Bottom)

The menu is fully rebuilt on every call to `rebuildMenu()`. All items are removed and re-created.

```
┌─────────────────────────────────────────────────┐
│ [If recording active:]                          │
│   🔴 Stop Recording · M:SS          (action)   │
│   [If one audio source failed:]                 │
│   ⚠ Microphone only — system audio  (disabled) │
│     not available                               │
│   ─────────────────────────────                 │
│                                                 │
│ [If model downloading/loading:]                 │
│   Downloading transcription model... (disabled) │
│   ─────────────────────────────                 │
│                                                 │
│ Upcoming Events                      (header)   │
│   [If authorized:]                              │
│     10:00 am – Team Standup          (submenu)  │
│     2:00 pm – Design Review          (submenu)  │
│   [If not determined:]                          │
│     Requesting calendar access…      (disabled) │
│   [If denied:]                                  │
│     Grant Calendar Access in System  (action)   │
│       Settings                                  │
│   [If no events:]                               │
│     No events today                  (disabled) │
│ ─────────────────────────────                   │
│ Recordings                           (header)   │
│   [If loading, no cache:]                       │
│     Loading...                       (disabled) │
│   [If empty:]                                   │
│     No recordings yet                (disabled) │
│   [If has recordings:]                          │
│     2:30 pm – Team Standup           (submenu)  │
│     Jan 10 – Product Review — Failed (submenu)  │
│ ─────────────────────────────                   │
│ New Recording                        (action)   │
│ Open Recordings Folder               (action)   │
│ Set API Key for Summaries...         (action)   │
│ Diagnostics                          (submenu)  │
│ Quit Meeting Recorder             ⌘Q (action)   │
└─────────────────────────────────────────────────┘
```

### Section Headers

Section headers ("Upcoming Events", "Recordings") are plain `NSMenuItem` instances with `isEnabled = false`. They appear as disabled text that acts as a label.

### Event Submenus

Each calendar event row has a submenu built by `buildEventSubmenu(for:)`:

```
┌─────────────────────────────┐
│ 10:00 am – 11:00 am  (disabled)  │
│ 5 attendees           (disabled)  │
│ ─────────────────────             │
│ Start Recording       (action)    │
│   [OR if this event is recording] │
│ Recording...          (disabled)  │
└─────────────────────────────┘
```

- Time range: disabled item showing start–end.
- Attendee count: disabled item, only shown if attendees exist.
- "Start Recording" is enabled only if no recording is active and no action is in flight. It carries an `EventRecordingContext` as `representedObject`.
- If this event is currently being recorded (matched by title + start time), shows "Recording..." instead.

### Recording Submenus

Each recording row has a submenu built by `buildRecordingSubmenu(for:)`:

```
┌────────────────────────────────────┐
│ [If summary completed:]            │
│   [View-based summary item]        │
│ [If summary generating:]           │
│   Generating summary... (disabled) │
│ [If summary failed:]               │
│   Summary Failed        (disabled) │
│   Retry Summary         (action)   │
│ [If no_api_key:]                   │
│   No API Key            (disabled) │
│   Retry Summary         (action)   │
│                                    │
│ ─────────────────────              │
│                                    │
│ [If transcription failed:]         │
│   Transcription Failed  (disabled) │
│   Retry Transcription   (action)   │
│ [If transcribing this recording:]  │
│   Transcribing...       (disabled) │
│ [If has transcript:]               │
│   Copy Transcript       (action)   │
│ [If no transcript:]                │
│   No transcript         (disabled) │
│ Show in Finder          (action)   │
└────────────────────────────────────┘
```

### Recording Row Title Format

Recording row titles include a status suffix appended by `recordingStatusSuffix(for:)`:

- **Today's recordings:** `"h:mm a – Title"` (e.g., `"2:30 pm – Team Standup"`)
- **Older recordings:** `"MMM d – Title"` or `"MMM d, yyyy – Title"` (if different year)
- **Status suffixes:**
  - `" — Transcribing…"` — transcription pending or in progress
  - `" — Failed"` — transcription failed
  - `" — Summarizing…"` — summary generating
  - `" — Summary Failed"` — summary failed
  - `" — No API Key"` — summary blocked on missing API key
  - (no suffix) — all complete or no summary yet

### Event Row Title Format

- `"h:mm a – EventTitle"` (e.g., `"10:00 am – Team Standup"`)

### Diagnostics Submenu

Built by `buildDiagnosticsSubmenu()`. Shows system state for debugging:

```
┌──────────────────────────────────────────────────┐
│ Screen Recording: Granted/Not Granted  (action*) │
│ Microphone: Granted/Not Granted        (action*) │
│ Calendar: Full Access/Denied/etc.      (action*) │
│ ─────────────────────                            │
│ [If recording active:]                           │
│   Capturing: System Audio + Microphone (disabled)│
│ ─────────────────────                            │
│ Transcription Model: Ready/Loading/etc (disabled)│
│ API Key: Configured/Not Set            (disabled)│
│ ─────────────────────                            │
│ Recordings: 42 (1.2 GB)               (disabled)│
└──────────────────────────────────────────────────┘
```

*Permission items are clickable only when not granted — they open the corresponding System Settings pane.

**Permission items:**
- Screen Recording: `CGPreflightScreenCaptureAccess()`. Opens `Privacy_ScreenCapture`.
- Microphone: `AVCaptureDevice.authorizationStatus(for: .audio)`. Opens `Privacy_Microphone`.
- Calendar: `EKEventStore.authorizationStatus(for: .event)`. Shows detailed status (Not Determined, Restricted, Denied, Write Only, Full Access). Opens `Privacy_Calendars`.

**Capture status** (only shown during active recording):
- "Capturing: System Audio + Microphone", "Capturing: Microphone Only", "Capturing: System Audio Only", or "Capturing: No Audio Sources".

**Pipeline status:**
- Transcription Model: "Loading" (idle/loadingModel), "Downloading" or "Downloading (X%)" (downloadingModel), "Ready" (ready/transcribing), "Error" (error).
- Download progress computed by checking which FluidAudio model files exist on disk vs required model count.
- API Key: "Configured" or "Not Set".

**Storage stats:**
- Shows `"Recordings: N (size)"` where N is the number of recording directories and size is the total disk usage formatted by `ByteCountFormatter`.
- Computed lazily in `refreshRecordingsStorageSnapshotIfNeeded()`. Runs on a detached utility-priority task.
- Cached with a 300-second max age. Marked stale on recording state changes, transcription/summary completion, and errors.
- Shows "Recordings: Calculating..." before the first snapshot completes.

### View-Based Items

**`RecordingSummaryMenuItemView`** is the only view-based menu item. It's an `NSView` subclass used for the summary display in recording submenus. It wraps an `NSTextField(wrappingLabelWithString:)` with:
- Font: `.menuFont(ofSize: 13)`
- Max lines: unlimited (`maximumNumberOfLines = 0`)
- Preferred text width: 280pt
- Horizontal padding: 12pt, vertical padding: 6pt
- Total width: 304pt
- Uses **frame-based sizing** (not Auto Layout): computes cell height via `cellSize(forBounds:)`, falls back to `fittingSize`.

All other items are standard `NSMenuItem` instances with `title`, `action`, `target`, and optional `submenu`.

### Menu Rebuild Triggers

`rebuildMenu()` is called from:
- `menuWillOpen` (every time the menu is opened)
- `recordingTimerFired` (if menu is open during recording — but only if `stopRecordingMenuItem` is nil; otherwise just updates the stop item title directly)
- State change callbacks from `AudioRecorder`, `TranscriptionManager`, `SummaryManager`
- After start/stop recording actions complete
- `statusTextTimerFired` (if menu is open)
- Calendar events changed (if menu is open)
- `refreshRecentRecordings` completion (if menu is open)

### Recording Timer

When a recording is active and the menu is open, a 1-second `Timer` updates the stop recording item's title with the current elapsed time. The timer is created in `configureRecordingTimerIfNeeded()` and invalidated in `stopRecordingTimer()` (called from `menuDidClose`). The timer directly updates `stopRecordingMenuItem.title` without a full rebuild (unless the item reference is nil).

### Status Text Timer

A 60-second `Timer` runs continuously on the main run loop (`.common` mode). It calls `updateStatusItemButtonAppearance()` to refresh the next-event text in the status bar. If the menu is open, it also calls `rebuildMenu()`.

---

## 5. Storage Format

### Root Directory

```
~/MeetingRecorder/recordings/
```

Created on demand by `RecordingStorage.ensureRecordingsRootExists()`.

### Recording Directory Naming

**Initial name (at recording start):**
```
YYYY-MM-DD_HHmm_slug/
```

- `YYYY-MM-DD` — date prefix from `startTime`.
- `HHmm` — time prefix from `startTime` (24-hour, no separator).
- `slug` — lowercase, alphanumeric + hyphens, max 40 chars. Derived from `eventTitle` (or `"recording"` if nil/empty).
- If a directory with the same name exists, appends `-2`, `-3`, etc.

**After title generation (rename):**

If the Claude API generates a title for an untitled recording, `applyGeneratedTitle` updates metadata and calls `renameDirectoryIfNeeded`. The new name uses the same format but with the generated title's slug.

If the recording already had a meeting title (from a calendar event), the generated title is stored in metadata but the directory is **not** renamed (because the meeting title takes precedence in `resolvedTitle`).

### Slug Generation

`RecordingStorage.slug(from:)`:
1. Trims whitespace. Falls back to `"Recording"` if empty.
2. Lowercases.
3. Replaces non-`[a-z0-9]` runs with `-`.
4. Trims leading/trailing hyphens.
5. Truncates to 40 characters (trimming trailing hyphens again).
6. Falls back to `"recording"` if result is empty.

### Directory Contents

```
YYYY-MM-DD_HHmm_slug/
├── metadata.json          # Always present after recording stops
├── recording.m4a          # Mixed audio output (M4A/AAC)
├── transcript.txt         # Present after successful transcription
└── summary.txt            # Present after successful summary generation
```

Temp files (`system-audio-temp.caf`, `mic-audio-temp.caf`) are created during recording and deleted in the `stopRecording` defer block.

### metadata.json Schema

```json
{
  "attendees": ["Alice", "Bob"],
  "audioFile": "recording.m4a",
  "calendarEvent": true,
  "date": "2025-02-11T14:30:00Z",
  "duration": 2723.5,
  "generatedTitle": "Sprint Planning Review",
  "meetingTitle": "Team Standup",
  "summaryFile": "summary.txt",
  "summaryStatus": "completed",
  "title": "Team Standup",
  "transcriptFile": "transcript.txt",
  "transcriptionStatus": "completed"
}
```

**Field details:**

| Field | Type | Description |
|-------|------|-------------|
| `title` | `String?` | Legacy/resolved title. Set to `meetingTitle` initially. Updated to `generatedTitle` if no meeting title exists. |
| `meetingTitle` | `String?` | The original title from the calendar event (or nil for ad-hoc recordings). Never changes after initial write. |
| `generatedTitle` | `String?` | Title generated by Claude API. Set by `applyGeneratedTitle`. Null until summary generation completes. |
| `date` | `String` | ISO 8601 datetime string (via `ISO8601DateFormatter` with `.withInternetDateTime`). The recording start time. |
| `duration` | `TimeInterval` | Audio duration in seconds (from the mixed `.m4a` file). |
| `attendees` | `[String]` | Attendee names from calendar event. Empty array for ad-hoc recordings or events without attendees. |
| `audioFile` | `String` | Always `"recording.m4a"`. |
| `calendarEvent` | `Bool` | `true` if recording was started from a calendar event, `false` for ad-hoc. |
| `transcriptionStatus` | `String?` | One of: `"pending"`, `"transcribing"`, `"completed"`, `"failed"`. Null initially (before transcription is requested). |
| `transcriptFile` | `String?` | `"transcript.txt"` when transcription is completed. Null otherwise. |
| `summaryStatus` | `String?` | One of: `"pending"`, `"generating"`, `"completed"`, `"failed"`, `"no_api_key"`. Null initially. |
| `summaryFile` | `String?` | `"summary.txt"` when summary is completed. Null otherwise. |

JSON is written with `.prettyPrinted` and `.sortedKeys` formatting.

### transcript.txt Format

```
Meeting: Team Standup
Date: Tuesday, February 11, 2025 at 2:30 PM
Duration: 45 minutes
Attendees: Alice, Bob
Summary: A brief 1-2 sentence summary of the meeting.

[Full transcription text from FluidAudio...]
```

**Header fields:**
- `Meeting:` — resolved title (meetingTitle > generatedTitle > "Recording").
- `Date:` — full date+time using `.full` date style and `.short` time style with current locale.
- `Duration:` — human-readable (e.g., "45 minutes", "1 hour 30 minutes", "less than a minute").
- `Attendees:` — comma-separated. Omitted if empty.
- `Summary:` — inserted after transcription by `updateTranscriptWithSummary`. Placed before the first blank line in the file.

The header is separated from the transcript body by a blank line.

### summary.txt Format

Plain text, 1-2 sentences. No header, no formatting. Just the summary string as returned by the Claude API.

### Title Resolution (RecordingInfo.title)

Used for display in the menu:
1. If `meetingTitle` is non-empty after trimming → use it.
2. Else if `generatedTitle` is non-empty after trimming → use it.
3. Else → `"Recording"`.

### Title for Summary Prompt (RecordingInfo.summaryPromptTitle)

Used as context for the Claude API:
1. If `meetingTitle` is non-empty → use it.
2. Else if `calendarEvent` is true and `generatedTitle` is non-empty → use generated title.
3. Else → `nil` (no title context sent to Claude).

---

## 6. Key Patterns & Gotchas

### Actor Isolation

- `RecordingStorage`, `AudioRecorder`, `TranscriptionManager`, `SummaryManager` are all actors. Every property access and method call from outside must be `await`ed.
- `RecordingStorage.rootURL` (which returns `recordingsRootURL`) is `nonisolated` (set once in `init`, never mutated). Safe to read from any context.
- `MenuManager` is `@MainActor`. It accesses actor methods via `Task { await ... }` blocks. All UI state (`currentRecordingState`, `transcriptionState`, `summaryState`, `cachedRecentRecordings`, etc.) is main-actor-isolated.
- `SystemAudioCapture` and `MicCapture` are **not** actors. They use manual synchronization (`DispatchQueue` and `NSLock`) because their callbacks come from system frameworks on specific queues.

### State Change Notification Pattern

All actors that need to push state to the UI follow the same pattern:

```swift
typealias StateChangeHandler = @MainActor @Sendable (StateType) -> Void

private var onStateChanged: StateChangeHandler?

private func notifyStateChanged(_ state: StateType) {
    guard let onStateChanged else { return }
    Task { @MainActor in
        onStateChanged(state)
    }
}
```

This ensures the callback always runs on `@MainActor`. The `Task` dispatch means delivery is asynchronous — there can be a brief delay between the actor state change and the UI update.

### Transcription Queue

- `TranscriptionManager` maintains a `queuedDirectoryURLs: [URL]` array.
- Only one transcription runs at a time. After one completes, `drainQueueIfNeeded` picks the next.
- `isDrainingQueue` flag prevents re-entrant drain calls.
- Deduplication: `enqueueForTranscription` checks if the URL is already in the queue or currently transcribing.
- State returns to `.ready` after each transcription (success or failure), which triggers the next drain cycle.

### Model Download on First Launch

- `TranscriptionManager.preloadModel()` is called from `applicationDidFinishLaunching` inside a `Task`.
- Downloads FluidAudio Parakeet TDT v3 model from HuggingFace (~600MB).
- State transitions: `.idle` → `.downloadingModel` → `.loadingModel` → `.ready` (or `.error`).
- The menu shows "Downloading transcription model..." or "Loading transcription model..." during these phases.
- If the model fails to load, `retryModelLoadOnceAfterFailure` will attempt one retry after 1.5 seconds when a transcription is requested.
- After model loads successfully, `runStartupReconciliationIfNeeded` runs before draining the queue.

### Startup Reconciliation

- Runs once, after the transcription model is loaded, guarded by `didRunStartupReconciliation`.
- Calls `recordingStorage.listAllRecordings()`.
- For each recording with `transcriptionStatus` of `"pending"` or `"transcribing"`: re-enqueues for transcription (if `recording.m4a` exists).
- For each recording with `transcriptionStatus == "completed"` and `summaryStatus` of `"pending"` or `"generating"`: re-enqueues for summary generation.
- This recovers from crashes or force-quits during transcription/summary.

### API Key Storage

- Stored in macOS Keychain using Security framework.
- Service: `"MeetingRecorder (Anthropic API Key)"`, Account: `"anthropic-api-key"`.
- `SummaryManager` caches the key in memory (`cachedApiKey`). On init, it reads from Keychain synchronously (`retrieveApiKeySync`).
- `storeApiKey` deletes the old entry first, then adds the new one.
- On 401 response from Claude API, the key is deleted from both cache and Keychain, and state is set to `.noApiKey`.
- The prompt dialog (`promptForApiKey`) is a static `@MainActor` method that shows an `NSAlert` with an `NSTextField` accessory view. Single-line, scrollable, no wrapping.

### Auto-Retry of no_api_key Recordings

When the user sets an API key via `setApiKeyTapped`, `MenuManager` scans `cachedRecentRecordings` for recordings with `summaryStatus == "no_api_key"` and `transcriptionStatus == "completed"`. For each matching recording, it calls `retrySummaryGeneration(directoryURL:)` which reads the transcript body and fires off `summaryManager.generateSummary(...)`.

### Calendar Events

- `CalendarManager` uses `EKEventStore` to fetch events.
- `fetchTodaysEvents()`: fetches events for the current calendar day, filters out all-day events and events that have already ended, sorts by start date ascending.
- Authorization: requests full access (`requestFullAccessToEvents`). Falls back to showing "Grant Calendar Access in System Settings" link.
- Observes `EKEventStoreChanged` notification to trigger menu/status bar updates when events change.
- Event-recording association: when starting a recording from an event, the `associatedEventStartTime` is stored. During menu build, `isEvent(_:currentlyRecordingWith:)` matches by title (case-insensitive) and start time (within 1 second tolerance).

### Graceful Termination

`AppDelegate.applicationShouldTerminate`:
1. If no recording active → `.terminateNow`.
2. If recording active → `.terminateLater`.
3. Starts a `Task` with a 10-second timeout race (`withTaskGroup`).
4. Calls `menuManager.stopRecordingForTermination()` — same as normal stop but without triggering transcription.
5. Marks the recording's transcript status as `"pending"` so startup reconciliation will pick it up next launch.
6. Calls `NSApplication.shared.reply(toApplicationShouldTerminate: true)`.

### Screen Capture Permission Request at Launch

`AppDelegate.applicationDidFinishLaunching` calls `CGPreflightScreenCaptureAccess()` to check if screen recording is already authorized. If not, it calls `CGRequestScreenCaptureAccess()` to trigger the system permission prompt. This is done before `menuManager.configure()` to give the user the best chance of granting permission before their first recording.

### Recording Action Guard

`recordingActionInFlight: Bool` prevents concurrent start/stop actions. Set to `true` before the async operation, `false` after completion. While true:
- "New Recording" and event "Start Recording" items are disabled.
- "Stop Recording" shows "Stopping..." text.
- `beginStartRecording` and `stopRecordingTapped` early-return.

### Audio Source Failure Alerts

After `startRecording` succeeds (at least one source available), `showSourceFailureAlertIfNeeded(for:)` checks the `RecordingState`:

- **System audio failed, mic OK:** Shows `NSAlert` with "System Audio Not Available" explaining only mic is recording. Offers "Continue" or "Open System Settings" (opens Screen Recording privacy pane).
- **Mic failed, system audio OK:** Shows `NSAlert` with "Microphone Not Available" explaining only system audio is recording. Offers "Continue" or "Open System Settings" (opens Microphone privacy pane).
- **Both failed:** `showBothSourcesFailedAlert()` shows an `NSAlert` with "Recording Failed" explaining neither source is available. Offers "OK" or "Open System Settings" (opens Privacy & Security root).

### Audio Source Warning in Menu

During active recording, if one audio source is unavailable, a warning item appears below the stop button:
- `"Microphone only — system audio not available"` (with `exclamationmark.triangle` SF Symbol)
- `"System audio only — microphone not available"` (with `exclamationmark.triangle` SF Symbol)

These are disabled `NSMenuItem`s that serve as informational indicators.

### Recent Recordings Cache

- `cachedRecentRecordings: [RecordingInfo]` is loaded asynchronously from `RecordingStorage`.
- `refreshRecentRecordings(force:)` cancels any in-flight refresh task and starts a new one.
- Called on menu open, after stop recording, and on transcription/summary state changes.
- The `Task` checks `Task.isCancelled` before updating cache.
- `hasLoadedRecentRecordings` tracks whether the first load has completed (shows "Loading..." until then).

### Copy Transcript Behavior

`copyTranscriptTapped` reads `transcript.txt` and calls `extractTranscriptBody` which strips the metadata header. It finds the first blank line that separates the header from the body, and copies only the body (the raw transcript text) to the clipboard. The header lines (Meeting, Date, Duration, Attendees, Summary) are not included.

### RecordingInfo Field: generatedTitle Fallback

In `RecordingStorage.recordingInfo(for:)`, the `generatedTitle` field in `RecordingInfo` is populated as:
```swift
generatedTitle: metadata.generatedTitle ?? normalizedOptionalTitle(from: metadata.title)
```
This means if `generatedTitle` is nil in metadata, it falls back to the legacy `title` field. This provides backward compatibility with recordings created before the `meetingTitle`/`generatedTitle` split was introduced.

### Sendable Compliance

- `RecordingState` and `TranscriptionResult` are `Sendable` structs (value types with `Sendable` fields).
- `RecordingInfo` is explicitly `Sendable`.
- `TranscriptionState` and `SummaryState` are explicitly `Sendable` enums.
- `CalendarEvent` is a plain struct (not marked `Sendable` explicitly, but all fields are `Sendable` types).
- `SystemAudioCapture` uses `@unchecked Sendable` wrappers (`AssetWriterBox`) to pass `AVAssetWriter` across concurrency boundaries.
- `AudioMixer` uses `ExportSessionBox` (also `@unchecked Sendable`) for `AVAssetExportSession`.
- `@preconcurrency import AVFoundation` is used in `AudioMixer`, `SystemAudioCapture`, and `MicCapture` to suppress pre-concurrency warnings from AVFoundation types.

### Error Handling Pattern

Each component defines its own error enum conforming to `LocalizedError`:
- `AudioRecorderError` (alreadyRecording, notRecording, noAudioSourcesAvailable, metadataWriteFailed)
- `SystemAudioCaptureError` (screenRecordingPermissionDenied, noDisplayAvailable, streamOutputUnavailable, captureStartFailed, captureStopFailed, writerPreparationFailed, writerFinalizationFailed)
- `MicCaptureError` (microphonePermissionDenied, microphoneInputUnavailable, writerNotPrepared)
- `AudioMixerError` (noAudioSourcesAvailable, exportSessionUnavailable, exportFailed)
- `SummaryError` (unauthorized, rateLimited, serverError, httpError, invalidResponse, parseError)
- `RecordingStorage.StorageError` (metadataUnavailable, transcriptWriteFailed)

Errors are logged via `NSLog`. Audio source failures during start trigger user-visible `NSAlert` dialogs. Other errors result in status suffixes in the menu (e.g., "— Failed", "— Summary Failed") with retry actions in submenus. System beep (`NSSound.beep()`) is used for unexpected failures in user actions.

### Audio Capture Details

**System audio (`SystemAudioCapture`):**
- Uses `SCStream` from ScreenCaptureKit.
- Captures a minimal 2x2 pixel display at 30fps (video is ignored; only audio is used).
- Audio config: 48kHz, 2 channels, queue depth 3.
- Writes to `.caf` file as linear PCM (16-bit, little-endian, interleaved).
- `AVAssetWriter` session starts lazily on first sample buffer.
- If no samples were written, `finalizeWriter` cancels the writer (produces no output file) rather than failing.
- `lastWriterError` is tracked and surfaced during `finalizeWriter`.

**Microphone (`MicCapture`):**
- Uses `AVAudioEngine` input node tap.
- Buffer size: 4096 frames.
- Format: whatever the input node's output format is (hardware-dependent).
- Writes to `.caf` via `AVAudioFile`.
- Permission check: `AVCaptureDevice.authorizationStatus(for: .audio)`. Requests access if `.notDetermined`.

**Mixing (`AudioMixer`):**
- Only processes files that exist and have non-zero size (`fileHasAudioData`).
- Creates `AVMutableComposition` with one track per valid input.
- Exports to `.m4a` using `AVAssetExportPresetAppleM4A`.
- Reports progress every 200ms during export.
- If both sources are available, both tracks are mixed into the output. If only one source is available, that source alone is used.

### FluidAudio Integration

- Import: `import FluidAudio` (in `TranscriptionManager` and `MenuManager`).
- Model: `AsrModels.downloadAndLoad(version: .v3)` — Parakeet TDT v3, runs on CoreML/ANE.
- ASR initialization: `AsrManager(config: .default)` then `manager.initialize(models:)`.
- Transcription: `asrManager.transcribe(audioFileURL, source: .system)`.
- Progress: `asrManager.transcriptionProgressStream` — an async stream of `Double` progress values.
- Result: `AsrResult` with `.text`, `.tokenTimings` (array of `TokenTiming` with `.token`, `.startTime`, `.endTime`), `.confidence`, `.duration`, `.processingTime`.
- The model handles audio format conversion internally — it accepts the `.m4a` file directly.
- Model auto-downloads from HuggingFace on first use (~600MB). Cached on disk after download.
- `MenuManager` uses `AsrModels.requiredModelNames` and `AsrModels.defaultCacheDirectory(for: .v3)` to compute model download progress for the diagnostics submenu.
- Attendee-aware name biasing is enabled for transcription:
  - `ParticipantNameResolver` extracts canonical spoken names from attendee metadata (including email local-parts like `venkat@...` -> `Venkat`).
  - `TranscriptionManager` lazily downloads/loads `CtcModels` (`.ctc110m`) and `CtcTokenizer` on first attendee-based transcription.
  - For each recording, attendee names are tokenized into `CustomVocabularyContext` terms and applied via `asrManager.configureVocabularyBoosting(...)`.
  - Biasing is best-effort: failures in CTC setup are logged and transcription continues without biasing.
  - `asrManager.disableVocabularyBoosting()` is always called after each transcription job to avoid cross-recording carryover.
  - CTC detected/applied terms are logged from `ASRResult.ctcDetectedTerms` and `ASRResult.ctcAppliedTerms`.

### Attendee-Aware Summary Prompting

- `SummaryManager.generateSummary(...)` now accepts `attendees`.
- Summary prompts include normalized attendee names and instruct Claude to prefer those spellings when referring to people.
- Canonical attendee names are derived with `ParticipantNameResolver`, ensuring summaries and transcripts use the same name normalization rules.

### Privacy Settings Deep Links

All privacy settings links use the extension URL format:
- Screen Recording: `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture`
- Microphone: `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone`
- Calendar: `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Calendars`

---

## 7. Feature Status

### Menu Bar Status Text
**Working.** When calendar access is authorized and there are upcoming events today, the status bar shows the next event's time and title (e.g., `"2:30 pm Team Standup"`). Truncated to 30 chars with "..." suffix. Updates every 60 seconds and on calendar change notifications. Shows nothing if calendar access is denied or no events remain today. When no text, shows icon only (`imagePosition = .imageOnly`).

### Recording Indicator
**Working.** When a recording is active, the status bar button switches to the `record.circle` SF Symbol (template image) with "Recording" text. If the `record.circle` symbol is unavailable (shouldn't happen on macOS 14.2+), falls back to text-only with `imagePosition = .noImage`. Tooltip changes to "Meeting Recorder: Recording". When recording stops, the waveform icon returns.

### Audio Source Failure Alerts
**Working.** After starting a recording, if one audio source failed, an `NSAlert` dialog explains which source is missing and offers to open System Settings. If both sources fail, a different alert explains the recording could not start. During recording, a warning item appears in the menu below the stop button with an `exclamationmark.triangle` icon indicating the degraded state.

### Stop Recording UI
**Working.** The first item in the menu during active recording is `"Stop Recording · M:SS"` with a `stop.fill` SF Symbol. The elapsed time updates every second while the menu is open (via `recordingTimer`). While the stop action is processing, the title changes to `"Stop Recording · Stopping..."` and the item is disabled. Format is `M:SS` or `H:MM:SS` for recordings over an hour.

### Error Visibility in Recording List
**Working.** Recording row titles in the menu include status suffixes indicating processing state: `" — Transcribing…"`, `" — Failed"`, `" — Summarizing…"`, `" — Summary Failed"`, `" — No API Key"`. These are computed by `recordingStatusSuffix(for:)` based on the recording's `transcriptionStatus` and `summaryStatus`.

### Retry Actions
**Working.** Recording submenus include retry options for failed operations:
- "Retry Transcription" — appears when `transcriptionStatus == "failed"`. Re-enqueues the recording for transcription via `TranscriptionManager.transcribe(directoryURL:)`.
- "Retry Summary" — appears when `summaryStatus == "failed"` or `"no_api_key"`. Reads the transcript body and calls `SummaryManager.generateSummary(...)`.

### Auto-Retry of no_api_key Recordings
**Working.** When the user sets an API key via "Set API Key for Summaries...", the app automatically retries summary generation for all recent recordings that have `summaryStatus == "no_api_key"` and `transcriptionStatus == "completed"`. This means setting the key the first time will retroactively generate summaries for all transcribed recordings.

### Diagnostics Submenu
**Working.** The "Diagnostics" menu item has a submenu showing: permissions status (Screen Recording, Microphone, Calendar), active capture sources (during recording), transcription model status with download progress, API key configuration status, and recordings storage stats (count and total size). Permission items link to System Settings when not granted.

### Screen Capture Permission Request at Launch
**Working.** `AppDelegate.applicationDidFinishLaunching` calls `CGPreflightScreenCaptureAccess()` and, if not already granted, `CGRequestScreenCaptureAccess()`. This proactively prompts the user for screen recording permission before their first recording attempt.

### Auto-Generated Titles
**Working.** After transcription completes and summary generation succeeds, the Claude API returns a `title` field (2-6 words). For recordings without a `meetingTitle` (ad-hoc recordings), this title is applied: stored in `metadata.json` as `generatedTitle`, the legacy `title` field is updated, and the recording folder is renamed to include the new slug. For calendar event recordings that already have a `meetingTitle`, the `generatedTitle` is stored but does not affect the display title or folder name.

### Summary Display
**Working.** Recording submenus show a view-based item (`RecordingSummaryMenuItemView`) containing the summary text. Unlimited lines, 280pt wide, word-wrapping, menu font at 13pt. If the summary is still generating, shows a disabled `"Generating summary..."` item. If summary failed, shows "Summary Failed" with a "Retry Summary" action. If no API key, shows "No API Key" with a "Retry Summary" action.

### Folder Renaming
**Working.** `applyGeneratedTitle` in `RecordingStorage` renames the recording directory after a generated title is available. It recomputes the slug from the resolved title and moves the directory. If the target name already exists, it appends `-2`, `-3`, etc. If the source and target are the same path, it's a no-op. If the rename fails (e.g., permissions), it logs and returns the original path.

### Calendar Filtering
**Working.** `CalendarManager.fetchTodaysEvents()` returns events for the current calendar day that: are not all-day events, have not yet ended, sorted by start date ascending. Events from all calendars are included (no calendar source filtering). Events with empty titles are shown as "Untitled Event".

### Startup Reconciliation
**Working.** On launch, after the transcription model loads, `runStartupReconciliationIfNeeded` scans all recordings. Recordings stuck in `"pending"` or `"transcribing"` transcription status are re-enqueued for transcription. Recordings with completed transcription but stuck in `"pending"` or `"generating"` summary status are re-enqueued for summary generation. Runs exactly once per app lifecycle.

### Ad-Hoc Recording
**Working.** The "New Recording" menu item starts a recording without a calendar event context. `eventTitle` is nil, `calendarEvent` is false, `attendees` is nil. The directory is named `YYYY-MM-DD_HHmm_recording/`. After summary generation, the folder may be renamed if a title is generated.

### Event Recording
**Working.** Clicking "Start Recording" in an event's submenu passes the event's title, start date, and attendees via `EventRecordingContext`. The recording is associated with the event via `associatedEventStartTime` and `calendarEvent: true`. The event's submenu shows "Recording..." instead of "Start Recording" while active.

### Copy Transcript
**Working.** Available in recording submenus for completed transcriptions. Reads `transcript.txt`, strips the metadata header, copies only the transcript body to the system clipboard.

### Open Recordings Folder
**Working.** Opens `~/MeetingRecorder/recordings/` in Finder. Creates the directory if it doesn't exist.

### Show in Finder
**Working.** Available in recording submenus. Opens Finder and selects the recording's directory.

### API Key Management
**Working.** "Set API Key for Summaries..." (or "Change API Key for Summaries..." if one exists) shows an `NSAlert` dialog. Key is stored in Keychain. On 401 from Claude API, key is auto-deleted and state resets to `.noApiKey`. Setting a new key triggers auto-retry of all no_api_key recordings.

### Graceful Termination
**Working.** If a recording is active when the app is quit, it stops the recording with a 10-second timeout, saves audio, writes metadata, and marks transcription as `"pending"` for next launch.
