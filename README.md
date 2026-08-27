# Meeting Recorder

A native macOS menu bar app that records system audio and microphone audio, transcribes meetings locally, and can optionally generate a short summary with Claude.

## Download

Download the latest build from [GitHub Releases](https://github.com/crosbycj/meeting-recorder/releases/latest).

The current build requires an Apple Silicon Mac running macOS 14.2 or later. It is ad-hoc signed but not Apple-notarized, so macOS may block the first launch. If that happens, try to open the app once, then go to **System Settings → Privacy & Security** and choose **Open Anyway**.

## What it does

- Records system audio and microphone audio, continuing with either source if the other is unavailable.
- Runs batch transcription locally using [FluidAudio](https://github.com/FluidInference/FluidAudio) and Parakeet TDT v3.
- Downloads the transcription model on first use (about 600 MB), then keeps it cached locally.
- Optionally sends the transcript to Anthropic's Messages API for a generated title and summary.
- Shows upcoming calendar events and recent recordings from a menu bar-only interface.
- Stores recordings and transcripts under `~/MeetingRecorder/`.

Meeting audio and local transcription do not require an API key. The optional summary feature requires an Anthropic API key, which the app stores in the macOS Keychain. When enabled, that feature sends transcript text to Anthropic.

## Build from source

Requirements:

- Apple Silicon Mac
- macOS 14.2 or later
- Xcode 16 or later

Open `MeetingRecorder.xcodeproj` in Xcode, allow Swift Package Manager to resolve FluidAudio, select the **MeetingRecorder** scheme, and run the app.

To produce the same ad-hoc-signed ZIP used for GitHub Releases:

```sh
./Scripts/package-release.sh
```

The archive is written to `dist/`.

## Permissions

Meeting Recorder may ask for microphone, calendar, notifications, and system-audio capture access. You can deny calendar access and still create recordings manually. The app is not sandboxed because it captures system audio.

## Project status

This is an early, source-available release. Review [AUDIT.md](AUDIT.md) for known limitations and areas that have not yet received full runtime testing.

## License

[0BSD](LICENSE). You can use, copy, modify, and distribute this software for any purpose, with or without a fee.
