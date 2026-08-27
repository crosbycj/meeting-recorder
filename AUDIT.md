# Meeting Recorder merge audit

Audit date: 2026-08-14
Scope: read-only source/configuration inspection plus a local build. No app launch, permission grant, recording, or model download/runtime transcription was performed.

## Executive conclusion

This is not a dead project. The recovered source builds on the current machine with Xcode 26.3, and its most valuable subsystem is a modern macOS 14.2+ Core Audio process-tap capture path—not ScreenCaptureKit and not a virtual audio driver. It already records system audio and microphone audio independently while capture is active and gracefully continues when either source is unavailable.

The product-ready seam stops there. On stop, the app exports both source files into one `recording.m4a`, deletes the two source CAF files, transcribes the combined output, discards the word timings it receives, and writes a human-oriented `transcript.txt`. After a successful remote Claude summary, it can delete the whole recording directory, including the audio and machine-readable metadata. There is no durable me/them channel contract, speaker attribution, timestamped transcript format, cursor insertion, global capture/copy hotkey, or LLM-oriented front matter.

Against the merged-product thesis, the best path is to retain/refactor the two capture implementations, the local ASR adapter, and the small AppKit menu-bar shell. The storage/export/transcript pipeline should be redesigned before reuse. Calendar should be extracted into an optional annotation provider. The Claude summary layer and meeting-app detection machinery should be removed.

Two checked-in descriptions are stale relative to the source: `AGENTS.md` says system capture uses ScreenCaptureKit and that recordings live under `~/MeetingRecorder/recordings/`; the implementation uses Core Audio process taps and the current root is `~/MeetingRecorder/`.

## 1. Inventory and build

### Project inventory

- Language: Swift. The project compiles in Swift 5 language mode.
- Build system: one Xcode project, `MeetingRecorder.xcodeproj`. There is no root `Package.swift` and no standalone SwiftPM product.
- Targets: one macOS application target, `MeetingRecorder`. There are no test targets and no test files.
- Product shape: AppKit menu-bar-only agent app. `LSUIElement = YES`; startup creates an `NSStatusItem` and runs without a Dock icon or main window.
- Minimum OS: macOS 14.2. This is meaningful, not arbitrary: `AudioHardwareCreateProcessTap` is available from macOS 14.2.
- Architecture: `ARCHS = arm64`; this is Apple Silicon-only. FluidAudio's Parakeet models also require Apple Silicon.
- Bundle: `com.cooper.MeetingRecorder`, version 1.0 (build 1).
- App Sandbox: disabled. Hardened Runtime: enabled.

Direct third-party dependency:

- FluidAudio, declared as `upToNextMajorVersion` from 0.7.9 and currently resolved to 0.12.0 at revision `9fcdf2f32cd879f494826db0e4945e8cf1187a62`.

Resolved transitive packages:

- `swift-collections` 1.3.0
- `swift-jinja` 2.3.1
- `swift-transformers` 1.1.6

`AppIntents.framework` is linked but no source imports or uses AppIntents. The project otherwise uses Apple frameworks: AppKit/Cocoa, AVFoundation, AudioToolbox/CoreAudio, CoreGraphics, EventKit, Security, ServiceManagement, and UserNotifications.

### Build result

The shell's active developer directory was initially `/Library/Developer/CommandLineTools`, so plain `xcodebuild` failed before evaluating the project:

```text
xcode-select: error: tool 'xcodebuild' requires Xcode, but active developer directory
'/Library/Developer/CommandLineTools' is a command line tools instance
```

Full Xcode was installed. Without changing the machine-wide selection, the audit used:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project MeetingRecorder.xcodeproj \
  -scheme MeetingRecorder -configuration Debug \
  -derivedDataPath /tmp/MeetingRecorderAuditDerivedData \
  -clonedSourcePackagesDirPath /tmp/MeetingRecorderAuditPackages \
  CODE_SIGNING_ALLOWED=NO build
```

Environment: Xcode 26.3 (17C529), macOS 26.2 SDK, arm64. After allowing Xcode to fetch the resolved packages, the build completed with `** BUILD SUCCEEDED **`. A second cached build also exited 0. The resulting executable is an arm64 Mach-O and its expanded Info.plist reports a 14.2 minimum OS.

One project-source warning appeared during the initial full compile:

```text
SystemAudioCapture.swift:349:81: warning: forming 'UnsafeMutableRawPointer'
to a variable of type 'CFString'; this is likely incorrect because 'CFString'
may contain an object reference.
```

That warning is in the Core Audio device-UID bridge and should be fixed before treating the capture code as production-ready. There are no compile errors. Build success does not verify TCC permission behavior, actual capture, device switching, stop/finalization, model download, or long-meeting transcription; those remain runtime tests.

Primary evidence: `MeetingRecorder.xcodeproj/project.pbxproj`, `MeetingRecorder/Info.plist`, `MeetingRecorder/main.swift`, `MeetingRecorder/AppDelegate.swift`.

## 2. Audio capture

### System audio API

System audio uses Core Audio process taps:

1. It resolves its own process to an `AudioObjectID`.
2. It creates `CATapDescription(stereoGlobalTapButExcludeProcesses:)`, excluding the recorder itself.
3. It calls `AudioHardwareCreateProcessTap`.
4. It creates a private aggregate audio device containing the default output device and the tap.
5. It installs an `AudioDeviceIOProcID`, copies callback buffers, and writes PCM float audio to a CAF file.

This is not ScreenCaptureKit (`SCStream` does not appear in source), not a third-party driver, and not the older virtual-device routing approach. Core Audio process taps are a current macOS API introduced in 14.2; they are not dead or deprecated in the macOS 26.2 SDK. ScreenCaptureKit is an alternative capture architecture, not a required replacement for this code.

Evidence: `MeetingRecorder/SystemAudioCapture.swift:97-214`.

### Microphone API

The microphone uses `AVAudioEngine` with an input-node tap. It can use the system-default microphone or a user-selected Core Audio device UID. It writes the mic input to a separate CAF file.

Evidence: `MeetingRecorder/MicCapture.swift:221-323`.

### Are system and mic separate?

During recording, yes:

- `system-audio-temp.caf`
- `mic-audio-temp.caf`

The capture boundary therefore has exactly the raw separation needed for cheap me/them attribution.

Durably, no reliable source separation survives:

- On stop, `AudioMixer` puts each available source into its own `AVMutableComposition` audio track at time zero and exports one `recording.m4a` using `AVAssetExportPresetAppleM4A`.
- There is no explicit channel mapping, left/right panning, source label, or durable manifest tying an output channel/track to `me` or `them`.
- Both source CAF files are then deleted unconditionally in `defer`.
- Transcription receives only `recording.m4a`; it does not transcribe each source separately.

So the app has separate capture stems transiently, but the current persisted/transcription contract does **not** provide free me/them speaker attribution. The merged product should preserve the two stems (or explicitly encode and label two channels/tracks) through transcription and formatting.

Evidence: `MeetingRecorder/AudioRecorder.swift:95-115`, `MeetingRecorder/AudioRecorder.swift:248-305`, `MeetingRecorder/AudioMixer.swift:32-130`.

### Graceful degradation

System and microphone startup are attempted independently. Recording proceeds with either one; it fails only when both sources fail. The UI warns when only one source is active. This behavior is genuinely reusable.

### Capture concerns

- A partial `SystemAudioCapture.start()` failure after creating the tap or aggregate device has no rollback path. `AudioRecorder` drops the failed object without calling `stop()`, so Core Audio resources can leak until process exit.
- The system-audio permission check is inferred from any process-tap creation failure, and the menu's “Granted” status is a sticky `UserDefaults` success flag. It can be stale after permission revocation and can misclassify non-permission failures.
- Silence detection performs per-sample RMS loops and emits extremely verbose diagnostics. Its product role should be reconsidered; capture itself should not depend on it.
- Final mix/export uses deprecated AVFoundation completion/status APIs; see section 9.

## 3. Transcription

### Engine and model

- Engine/library: FluidAudio 0.12.0.
- ASR model: Parakeet TDT 0.6B v3, Core ML (`FluidInference/parakeet-tdt-0.6b-v3-coreml`). It is not Whisper.
- `AsrModels.downloadAndLoad(version: .v3)` downloads the model on first use and loads it into Core ML. Inference is local after download; the initial model acquisition requires network access and is not offline-from-first-launch.
- With calendar attendees, the app optionally downloads/loads a second Parakeet CTC 110M model and uses attendee names as vocabulary-bias terms. This improves name spelling; it is not speaker identification.

Evidence: `MeetingRecorder/TranscriptionManager.swift:104-138`, `MeetingRecorder/TranscriptionManager.swift:448-509`, and the resolved FluidAudio 0.12.0 source/package lock.

### Batch versus streaming

App behavior is batch-only. Recording stops and the M4A is finalized before `TranscriptionManager.transcribe(directoryURL:)` runs. There is no live partial text during capture.

FluidAudio's use of “streaming” for long input is different: with the default configuration, a file over 480,000 resampled samples (about 30 seconds at 16 kHz) is read through a disk-backed sample source to cap memory. The pinned implementation processes roughly 14.9-second windows with 2 seconds of overlap plus 80 ms of left mel context, then merges token windows. This is a sound long-file strategy, but it remains post-recording batch transcription.

Evidence: `MeetingRecorder/MenuManager.swift:1826-1865`, `MeetingRecorder/TranscriptionManager.swift:267-380`; FluidAudio 0.12.0 `AsrManager`, `AsrTranscription`, and `ChunkProcessor` inspected at the resolved revision.

### Output quality and missing structure

FluidAudio returns token timings. The app maps them into `TranscriptionResult.WordTiming`, but `RecordingStorage.saveTranscriptFile` ignores `words`, confidence, audio duration, and processing time and writes only the flat text. There is no diarization and no speaker attribution. The app always invokes ASR with `source: .system` even though the input is the combined recording; in FluidAudio this chooses decoder state, not source separation.

The local ASR adapter is reusable, especially its queue, progress reporting, first-run model state, and startup reconciliation. The transcript assembly is not.

## 4. Calendar

### API and uses

Calendar access uses EventKit with `EKEventStore.requestFullAccessToEvents`.

It is used for:

- Listing today's remaining non-all-day events in the menu bar.
- Calendar selection/filtering.
- Event title, scheduled start/end, persistent event ID, attendee display names, and recurrence classification.
- Extracting Zoom, Google Meet, or Teams links from the event URL, location, or notes.
- A notification at event start (for events beginning within six hours) whose action opens the meeting URL and starts recording.
- Grouping recordings of recurring events into a series folder.
- Marking an event as already recorded in the menu.
- Biasing ASR toward attendee names.
- Lowering the silence timeout after the scheduled end time.
- A one-time storage migration that uses 90 days of calendar history to infer recurring series.

It does **not** silently auto-start recording from EventKit. Calendar reminders require the user to choose “Open Meeting & Record.” Separate meeting-app detection can notify the user and offer “Start Recording,” but that path is not calendar-driven.

Evidence: `MeetingRecorder/CalendarManager.swift:104-297`, `MeetingRecorder/CalendarManager.swift:299-419`, `MeetingRecorder/MenuManager.swift:761-939`, `MeetingRecorder/RecordingStorage.swift:673-770`.

### Entanglement verdict

Calendar is not load-bearing for capture or transcription. With access denied, “New Recording” still creates an ad-hoc capture with nil event fields, and storage places it under `Other Recordings`. The calendar fields in `RecordingState`/metadata are optional or have non-calendar defaults.

It is nevertheless structurally entangled in three places:

- The app requests full calendar access unconditionally at startup and devotes the top menu section/status text to calendar state.
- Recurrence controls the storage hierarchy.
- Attendees flow directly into metadata, UI, summary prompts, and ASR vocabulary boosting.

Recommendation: keep the EventKit parsing/enrichment logic only as an optional post-detection annotator. It should return optional capture metadata and must not choose folder hierarchy, own startup permission flow, or gate the base product. Ask for calendar access only when the user enables enrichment.

## 5. Storage and transcript format

### Actual location and naming

The current root is:

```text
~/MeetingRecorder/
```

It is **not** `~/MeetingRecorder/recordings/`; that is treated as a legacy location for migration.

Current layouts are:

```text
~/MeetingRecorder/<sanitized recurring-series title>/YYYY-MM-DD[-N]/
~/MeetingRecorder/Other Recordings/YYYY-MM-DD_HHmm_<slug>[-N]/
```

An active/non-collapsed recording directory can contain:

```text
system-audio-temp.caf   # only while recording; deleted on stop
mic-audio-temp.caf      # only while recording; deleted on stop
recording.m4a
metadata.json
transcript.txt
summary.txt             # only after remote summary succeeds
```

Evidence: `MeetingRecorder/RecordingStorage.swift:145-229`, `MeetingRecorder/AudioRecorder.swift:108-115`.

### Transcript format

Despite the product recollection of Markdown files, source writes `transcript.txt`. It is plain text with a human-oriented header, not YAML front matter:

```text
Meeting: <title>
Date: <localized full date and short time>
Duration: <human duration>
Attendees: <comma-separated names>   # omitted when empty
Summary: <one-line summary>          # inserted only after summary succeeds

<flat transcript text>
```

There are no `---` delimiters, stable field keys/types, ISO timestamps in the transcript, per-utterance timestamps, speaker labels, source labels, or confidence values. The localized date and human duration are poor machine interchange fields. Token timings exist in memory and are thrown away.

Evidence: `MeetingRecorder/RecordingStorage.swift:419-490`, `MeetingRecorder/Models/TranscriptionResult.swift`.

### Are audio files kept?

Only conditionally, and the current behavior is dangerous for the merged product:

- Before summary success, the directory retains `recording.m4a`, metadata, and transcript.
- When transcription **and** Claude summary both complete, `collapseCompletedRecording` copies `transcript.txt` to a sibling `.txt` file and deletes the entire recording directory. That removes the M4A, `metadata.json`, and `summary.txt`.
- A startup migration repeats this destructive collapse for older completed recordings.
- If there is no API key or summary fails, the directory and audio remain.

Thus retention depends accidentally on remote-summary state. For the new product, storage should be explicit and summary-independent. Preserve source stems at least until source-aware transcription/formatting completes; make any audio deletion an explicit retention policy.

Evidence: `MeetingRecorder/RecordingStorage.swift:594-639`, `MeetingRecorder/RecordingStorage.swift:801-852`, `MeetingRecorder/MenuManager.swift:357-371`.

## 6. Clipboard flow

“Copy Transcript” is a submenu action on a recent recording. It:

1. Resolves either the collapsed `.txt` file or `<directory>/transcript.txt`.
2. Reads the whole file.
3. Clears `NSPasteboard.general`.
4. Writes the full file as a plain string.

The copied value includes the header and summary when present; it is not just the transcript body. There is no copy confirmation, no automatic copy when transcription completes, no format choice, and no direct insertion at the current cursor.

There are no global hotkeys. The only non-empty menu key equivalent is `q` for Quit. No Carbon hotkey registration, event tap, `NSEvent` global monitor, or keyboard-shortcut package exists.

The pasteboard write is reusable as a tiny utility. The merged product needs a new destination layer for cursor insertion, explicit clipboard output, and folder output, plus a global capture/stop/copy shortcut if desired.

Evidence: `MeetingRecorder/MenuManager.swift:993-1001`, `MeetingRecorder/MenuManager.swift:2097-2118`.

## 7. Menu-bar UI

The app uses `NSStatusBar.system.statusItem` with a normal `NSMenu`.

Status item:

- Idle robot icon; on non-notched displays it also shows the next calendar event or “No events today.”
- Recording robot icon plus `Listening HH:MM:SS` where space allows.
- “Stopping…”, “Transcribing…”, “Generating summary…”, and model download/load states.
- Icon-only mode on notched displays, with the state in the tooltip.

Menu contents:

- While recording: Stop Recording with elapsed time and a one-source warning if needed.
- Transcription model download/load status.
- Upcoming Events with event time, attendee count, and Start Recording or Open Meeting & Record.
- Recent Recordings from the last seven days. Each row includes date/time, title, and processing failure/state suffix.
- A recent-recording submenu can show the remote summary and attendees, copy the transcript, retry transcription/summary, and reveal the item in Finder.
- New Recording.
- Open Recordings Folder.
- Settings: permissions, microphone choice, launch at login, automatic meeting detection, calendar selection, Anthropic API key, and model cache/status.
- Quit.

The AppKit status-item shell and live recording/processing state grammar are reusable. The current information architecture is not aligned with “no library UI” or optional calendar: calendar dominates the idle surface and the menu embeds a seven-day transcript library plus summary UI. Retain a much smaller shell—capture state, last-result copy/reveal, destination/settings, quit—and let Finder remain the archive.

Evidence: `MeetingRecorder/MenuManager.swift:483-747`, `MeetingRecorder/MenuManager.swift:761-1018`, `MeetingRecorder/MenuManager.swift:1020-1150`.

## 8. Permissions and prompt timing

### Required for core capture

- **Screen & System Audio Recording:** needed by the Core Audio process tap. There is no explicit preflight/request call; macOS is expected to prompt when `AudioHardwareCreateProcessTap` is first attempted, which happens when a recording starts. The same privacy domain also affects reading other apps' window titles used by meeting detection.
- **Microphone:** requested with `AVCaptureDevice.requestAccess(for: .audio)` on the first recording attempt if status is not determined.

Either capture permission can be denied and the app continues with the other source. Both denied/unavailable causes recording startup to fail.

### Requested at app startup

- **Notifications:** requested immediately at launch for alerts and sound. Used for calendar reminders, meeting detection, silence, and meeting-ended messages.
- **Calendar full access:** requested immediately at launch through EventKit, even though ad-hoc recording does not require it. This should become opt-in for the merged product.

### Other access/configuration

- **Keychain:** used only for the Anthropic API key. Keychain may show an access prompt depending on signing/keychain state. This subsystem should be removed with summaries.
- **Network:** no OS permission dialog, but required to fetch FluidAudio models on first use and currently required for Claude summaries.
- **Launch at login:** optional via `SMAppService.mainApp`.
- **Filesystem:** the unsandboxed app writes directly to `~/MeetingRecorder/`; there is no folder picker or security-scoped bookmark.

The app does not request Accessibility, Input Monitoring, Automation/Apple Events, Contacts, Location, or Photos. It has `ENABLE_RESOURCE_ACCESS_CAMERA = YES` in build settings but contains no camera code or camera usage description; this appears to be stale project configuration, not a runtime requirement.

The Info.plist contains both `NSCalendarsFullAccessUsageDescription` and the older `NSCalendarsUsageDescription`, plus `NSMicrophoneUsageDescription`. There is no separate usage-description key for Core Audio process taps.

## 9. Verdict and risks

### Ranked: genuinely reusable

1. **Separate system/mic capture boundary, after hardening.** `SystemAudioCapture` uses the right modern primitive for macOS 14.2+, and `MicCapture` is straightforward AVAudioEngine capture. Preserve separate source identity instead of deleting it.
2. **FluidAudio batch ASR adapter and long-file behavior.** The Parakeet v3/Core ML path is local, builds now, produces timings, handles large files in bounded memory, and has useful model/progress/recovery states. Put it behind a narrow transcription protocol and pin dependency/model behavior deliberately.
3. **Graceful one-source fallback and source-state UI.** Continuing with mic-only or system-only is correct capture-layer behavior.
4. **Serialized storage/job ideas.** `RecordingStorage` being an actor and the pending/transcribing startup reconciliation are good patterns. Reuse the concurrency/recovery approach, not the current schema, hierarchy, or collapse logic.
5. **Small AppKit menu-bar shell.** `NSStatusItem` + `NSMenu`, elapsed recording state, native mic selection, launch-at-login control, and Finder reveal fit the product's invisible utility character.
6. **Calendar parsing as an optional adapter.** Event title/time/attendees/meeting-link extraction can enrich a capture, but only after it is detached from storage and startup.

### Ranked: rewrite or remove

1. **Rewrite the durable capture/storage/export contract.** Persist two named sources or an explicitly labeled channel layout. Remove summary-dependent deletion. Define a stable capture-session manifest and explicit retention policy.
2. **Rewrite transcript formatting.** Produce LLM-oriented Markdown with machine-readable front matter, stable timestamps, and source-derived `Me`/`Them` turns. Use the token timings currently discarded. Do not use localized prose fields as metadata.
3. **Build a new destination dispatcher.** Cursor insertion, clipboard, and folder outputs do not exist as a coherent layer. Clipboard currently copies only a whole legacy file from the menu.
4. **Remove `SummaryManager` and all summary state/UI/storage coupling.** It sends transcripts to Anthropic, contradicts fully local capture, controls ad-hoc naming, and triggers destructive collapse. For this product thesis it is dead code, regardless of whether the HTTP API still works.
5. **Reduce/rewrite `MenuManager`.** At 2,484 lines it owns capture orchestration, calendar, model state, summary, permissions, storage lists, notifications, detection, and a settings window. Keep the status-item presentation but split responsibilities and remove the embedded seven-day library.
6. **Remove automatic meeting-app detection unless separately justified.** Core Audio process inspection, `pgrep CptHost`, and window-title heuristics for Zoom/Teams/Meet/Slack/FaceTime/Discord are brittle and outside the core audio-to-destination thesis. `CGWindowListCopyWindowInfo` is not formally deprecated in the current SDK; if window enumeration were retained, ScreenCaptureKit's `SCShareableContent`/`SCWindow` is the more structured modern API. Deletion is preferable here.
7. **Make EventKit optional.** Stop requesting it on launch and stop allowing recurrence to define storage layout.

### Deprecated/dead API findings

- `AVAssetExportSession.exportAsynchronously(completionHandler:)`, `status`, and `error` used by `AudioMixer` are deprecated from macOS 15. Replace the callback/status switch with `try await exportSession.export(to: outputURL, as: .m4a)`. If progress observation remains, use `states(updateInterval:)` rather than polling `progress`/`status`.
- Core Audio process taps (`CATapDescription`, `AudioHardwareCreateProcessTap`) are current and are the modern API here. Do not rewrite them merely because `AGENTS.md` says ScreenCaptureKit.
- `NSStatusItem`, EventKit's full-access request, `AVAudioEngine`, and `CGWindowListCopyWindowInfo` are not marked deprecated in the inspected macOS 26.2 SDK.
- The summary subsystem is “dead” because it violates the new product boundary, not because Foundation, Security, or URLSession are deprecated.

### Top three risks

1. **Runtime capture/TCC and Core Audio resource risk.** A compile pass cannot validate real system-audio capture across permission states, output-device changes, sleep/wake, Bluetooth devices, aggregate-device cleanup, or long sessions. The stale permission flag, unsafe CFString bridge warning, and missing rollback after partial startup failure are concrete warning signs. This needs live hardware tests before reuse.
2. **Data-loss and source-loss risk.** The app destroys system/mic stems after mix and can destroy all audio/JSON after a successful remote summary. That is directly opposed to source-aware transcription and makes recovery behavior depend on unrelated AI state. Replace this pipeline before importing old behavior.
3. **Dependency/provenance bitrot risk.** There is no Git history in the recovered folder and no tests. FluidAudio is still a 0.x dependency; the project declaration permits any compatible version from 0.7.9 while `Package.resolved` currently selects 0.12.0, and model delivery depends on external Hugging Face artifacts. Pin and wrap it, add fixture-based long-audio/timing tests, and validate the exact model/cache behavior before merging.

## Recommended merge boundary

The clean extraction boundary is:

```text
Core Audio system stem ─┐
                        ├─> capture session ─> source-aware local ASR ─> formatter ─> cursor / clipboard / folder
AVAudioEngine mic stem ─┘                         ↑
                                                  optional EventKit annotation
```

Import/refactor `SystemAudioCapture`, `MicCapture`, the source fallback state, and a narrowed FluidAudio adapter. Design a new session manifest, transcript formatter, and destination layer around them. Do not carry over `SummaryManager`, destructive collapse, calendar-shaped folders, recent-recording library UI, or meeting-app detection by default.
