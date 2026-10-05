# Bundled voice previews

These clips are AI-generated with `gpt-live-1`, one session per named voice, with
`store=false`. They contain the same synthetic English and Chinese text. No
microphone capture, meeting data, or third-party recording is used.

The application plays these local PCM16, mono, 24 kHz WAV files without a network
request or API key. `manifest.json` records the returned transcripts, durations,
and SHA-256 checksums; it is development metadata and is not copied into the app.

Validate the assets before packaging:

```sh
python3 scripts/check-voice-previews.py
```

To regenerate a clip, install Python `websockets` (tested with 12.0), provide
`OPENAI_API_KEY` in the process environment, then run:

```sh
python3 scripts/generate-voice-previews.py --voice marin
```

Generation calls the OpenAI API and uses the supplied account's quota. The script
verifies the acknowledged model and voice and checks the returned transcript.
Review regenerated audio before distributing it. Never commit credentials.

Session configuration follows the [GPT-Live guide](https://developers.openai.com/api/docs/guides/live-conversations#voice-options).
These short samples help compare voices; they do not validate translation quality
or voice consistency throughout a long meeting.
