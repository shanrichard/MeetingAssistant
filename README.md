<p align="center">
  <img src="Resources/AppIcon.png" width="112" height="112" alt="Meeting Assistant icon">
</p>

<h1 align="center">Meeting Assistant</h1>

<p align="center">Live bilingual captions, translated speech, and meeting notes for macOS.</p>

<p align="center">
  <strong>English</strong> · <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14.2%2B-222222?logo=apple&amp;logoColor=white" alt="macOS 14.2 or later">
  <img src="https://img.shields.io/badge/Swift-5.10%2B-F05138?logo=swift&amp;logoColor=white" alt="Swift 5.10 or later">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache--2.0-blue" alt="Apache License 2.0"></a>
  <img src="https://img.shields.io/badge/status-prototype-orange" alt="Prototype">
</p>

A native SwiftUI app that captures your microphone and system audio, shows live captions with translations, and turns the saved transcript into a summary with references. Bring your own OpenAI API key; no developer-hosted backend is required.

> **Project status:** prototype, source version **0.1.12 (14)**. Offline checks pass, while fresh-machine installation and real remote-listener acceptance remain work in progress. The app interface is currently primarily Simplified Chinese; this README is available in both languages.

## Features

- **Live bilingual captions** — original speech and translation together, with automatic scrolling you can pause to review earlier text.
- **Two audio sources** — microphone and system audio are recorded separately on a shared timeline.
- **Translated speech** — send AI-generated speech to a meeting through a virtual audio device, with automatic system-input switching and restoration.
- **Transcript-based summaries** — summarize the live text already received, with references back to the transcript. Failed summaries preserve existing notes and source text.
- **Local meeting library** — keep recordings and transcripts on your Mac, export Markdown, and delete individual meetings.
- **Your own credentials** — API keys are saved in macOS Keychain. There are no shared keys or analytics services.

## Quick start

### Requirements

| Requirement | Details |
| --- | --- |
| macOS | 14.2 or later; Apple silicon is the current development target. Intel has not been validated. |
| Build tools | Xcode or Command Line Tools with Swift 5.10+ and a compatible macOS SDK. Some optional developer scripts also use Python 3. |
| OpenAI | Your own API key and access to the models configured in the source. API usage is billed to your account. |
| Translated speech | A virtual audio device such as [BlackHole 2ch](https://existential.audio/blackhole/). It is not required just to record or display captions. |

The app currently configures `gpt-realtime-translate` with `gpt-live-transcribe` for live audio, and `gpt-5.6-luna` for summaries. API access and connectivity are required; this is not an offline transcription model.

### Build from source

No prebuilt app is attached to this repository yet.

```sh
git clone https://github.com/shanrichard/MeetingAssistant.git
cd MeetingAssistant
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
bash scripts/build-app.sh
open dist/MeetingAssistant.app
```

There are no third-party Swift package dependencies. The build script creates a local development signing identity when `MEETING_SIGNING_IDENTITY` is unset. Its signing material stays under `~/Library/Application Support/MeetingAssistant/DevelopmentSigning/`; a development build is not a notarized distribution package.

If the compiler reports an incompatible SDK, select a matching Xcode/Command Line Tools installation or set `SDKROOT` to an installed compatible SDK. The scripts use `--disable-sandbox` for SwiftPM's build-plugin sandbox; this does not disable macOS security settings.

### Start a meeting

1. Open Settings, enter your OpenAI API key, choose **Save**, then verify the connection.
2. Select a physical microphone, the caption/summary language, and the language you want to speak to others.
3. Start a meeting and grant the requested microphone and system-audio permissions. Headphones are recommended.
4. End the meeting to save the live transcript and recordings, then generate a summary from the transcript. You can retry a failed summary later.

## Send translated speech

The app detects an existing BlackHole 2ch device. If it is missing, the setup flow can download the official installer after you choose to proceed. The download is checked against a pinned SHA-256, publisher signature, and Gatekeeper before macOS Installer opens. Installation may require administrator authorization and a restart.

1. Select the virtual device as the app's translated-audio output.
2. Configure the meeting app to follow the **system default microphone**. A fixed device selection will not follow automatic switching.
3. Enable **Send my translated speech**. Meeting Assistant keeps capturing the physical microphone while switching the system input to the virtual device.
4. Ask another participant to confirm what they hear. Stopping, pausing, ending, or quitting normally restores the original input; a later launch attempts recovery after an abnormal exit.

The meeting app's mute control remains separate. Let participants know that the translated voice is AI-generated. Speech already in the target language may produce no translated audio, so original-speech passthrough is not guaranteed.

[BlackHole](https://github.com/ExistentialAudio/BlackHole) is a separate project by Existential Audio Inc. Its installer is downloaded from the publisher and is not bundled in this repository; its own license applies.

## Privacy and data

| Data | Handling |
| --- | --- |
| API key | Stored in macOS Keychain; used to authenticate directly with the official OpenAI API. Not written into meeting records or exports. |
| Live audio | Saved locally and sent to OpenAI during active captioning/translation. |
| Saved recordings | Kept on your Mac; the post-meeting summary flow does not upload them for another transcription pass. |
| Summary input | Only the saved live transcript is sent to OpenAI. Empty or missing live text does not trigger an audio-upload fallback. |
| Markdown export | Text and time references; no audio files or credentials. |

Meeting files are stored in `~/Library/Application Support/MeetingAssistant/Meetings/`. The app connects directly to OpenAI without a shared proxy or telemetry backend. Deleting a meeting removes its local records and recordings; previously exported files remain separate.

## Development

Run the baseline offline checks from the project root:

```sh
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
swift run --disable-sandbox --build-system native MeetingCoreChecks
swift run --disable-sandbox --build-system native AudioSafetyChecks
bash scripts/check-voice-output.sh
bash scripts/check-blackhole-setup.sh
```

These commands use synthetic data or simulated dependencies and do not call OpenAI, capture a meeting, or change system audio routing. Additional hardware checks can play silent audio or temporarily switch devices: review the [validation guide (中文)](docs/验证记录.md) before running them.

| Path | Purpose |
| --- | --- |
| `Sources/MeetingAssistant/` | SwiftUI app, capture, devices, playback, and routing |
| `Sources/MeetingCore/` | Models, persistence, credentials, API clients, and transcript handling |
| `Sources/AudioSafety/` | Objective-C audio exception boundary |
| `Sources/MeetingDiagnostics/` | Optional online developer diagnostics; requires explicit API credentials |
| `Tests/` | Standalone regression programs and synthetic UI scenarios |
| `scripts/` | Build, signing, icon generation, and validation helpers |

See the [design overview (中文)](docs/方案.md), [validation guide (中文)](docs/验证记录.md), and [icon notes (中文)](docs/图标设计.md).

### Signing and distribution

Use your own Developer ID identity through `MEETING_SIGNING_IDENTITY` for distributable builds. Each package still needs notarization, Gatekeeper verification, and installation/upgrade testing. Local self-signed builds can require renewed Keychain authorization after a binary change.

Archive creation and cloud-signing instructions are in the [signing guide (中文)](docs/签名与分发.md). Signing credentials and certificates are not included in the repository.

## Known limitations

- Real remote-listener acceptance across Meet, Zoom, Teams, and Lark is still pending. Local playback counters do not prove that another participant heard translated speech.
- Only the two audio sources are distinguished; remote speakers are not individually identified.
- There is no dedicated acoustic echo cancellation for speaker playback. Use headphones.
- Captions missed during a connection failure are not reconstructed from recordings afterward.
- Fresh-machine setup, long sessions, device interruptions, the minimum macOS version, and Intel builds need further validation.

See the [acceptance checklist (中文)](docs/验证记录.md#待完成的实机验收) for the current testing scope.

## Contributing

Bug reports, documentation improvements, and focused pull requests are welcome. For larger changes, [open an issue](https://github.com/shanrichard/MeetingAssistant/issues) first to discuss the approach.

Include your macOS version, hardware, reproduction steps, and expected versus actual behavior. Run the relevant offline checks and describe any hardware or online testing separately. Keep the English and Chinese READMEs in sync. Use synthetic examples and redact logs; never attach API keys, signing material, private recordings, or meeting transcripts.

## License

Copyright 2026 shanrichard. Licensed under the [Apache License, Version 2.0](LICENSE). See [NOTICE](NOTICE) for attribution.
