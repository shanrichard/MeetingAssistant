#!/usr/bin/env python3
"""Render bundled, synthetic GPT-Live previews. Requires Python websockets and OPENAI_API_KEY.

Never captures a microphone or reads meeting data. Every session has store=false.
Run from the repository root; review the returned transcripts and audio before release.
"""
import argparse
import asyncio
import array
import base64
import collections
import hashlib
import json
import os
import pathlib
import ssl
import sys
import time
import uuid
import wave

from websockets.legacy.client import connect

VOICES = "marin quartz ripple vesper willow stone gleam meridian bossa tempo beacon delta cinder".split()
TEXT = "Hello, this is a preview of my voice. I will translate your words clearly and naturally. 你好，这是我的声音试听。我会清晰、自然地为你翻译。"


def normalized(text):
    return "".join(c.lower() for c in text if c.isalnum())


async def render(voice, key, directory):
    context = ssl.create_default_context(cafile="/etc/ssl/cert.pem" if sys.platform == "darwin" else None)
    pcm, transcript = bytearray(), ""
    events = collections.Counter()
    async with connect(
        "wss://api.openai.com/v1/live/sessions", ssl=context,
        extra_headers={"Authorization": "Bearer " + key}, max_size=8 * 1024 * 1024,
        open_timeout=20, close_timeout=3,
    ) as ws:
        async def send(event):
            await ws.send(json.dumps({"event_id": str(uuid.uuid4()), **event}))

        await send({"type": "session.start", "session": {
            "model": "gpt-live-1", "store": False,
            "instructions": "You are recording one short bilingual voice sample. Read only the requested text once, exactly as written. Speak at a natural meeting pace. Never delegate or add commentary. After the sample, remain silent.",
            "audio": {"format": {"type": "audio/pcm", "rate": 24000}, "output": {"voice": voice}},
            "delegation": {"type": "client"},
        }})
        while True:
            event = json.loads(await asyncio.wait_for(ws.recv(), timeout=20))
            if event["type"] == "error":
                raise RuntimeError(str(event.get("error")))
            if event["type"] == "session.started":
                session = event["session"]
                assert session["model"] == "gpt-live-1" and session["audio"]["output"]["voice"] == voice
                break

        async def silence():
            silence_b64 = base64.b64encode(bytes(4800)).decode()
            while True:
                await send({"type": "session.input_audio.append", "audio": silence_b64})
                await asyncio.sleep(0.1)

        sender = asyncio.create_task(silence())
        try:
            # Let the input timeline advance before asking for unsolicited speech.
            await asyncio.sleep(1)
            await send({"type": "session.instructions.append", "delegation_id": None,
                        "content": "Begin speaking immediately. Read this English and Chinese text exactly once, then stay silent: " + TEXT})
            deadline = time.monotonic() + 40
            last_sound = time.monotonic()
            while time.monotonic() < deadline:
                try:
                    event = json.loads(await asyncio.wait_for(ws.recv(), timeout=0.5))
                except asyncio.TimeoutError:
                    event = {}
                kind = event.get("type")
                if kind: events[kind] += 1
                if kind == "error":
                    raise RuntimeError(str(event.get("error")))
                if kind == "session.output_audio.delta":
                    chunk = base64.b64decode(event["delta"], validate=True)
                    assert len(chunk) % 2 == 0
                    pcm.extend(chunk)
                    samples = array.array("h", chunk)
                    if sys.byteorder != "little": samples.byteswap()
                    if samples and max(abs(x) for x in samples) > 220:
                        last_sound = time.monotonic()
                elif kind == "session.output_transcript.delta":
                    transcript += event["delta"]
                if normalized(transcript) == normalized(TEXT) and time.monotonic() - last_sound > 1.5:
                    break
            await send({"type": "session.close"})
        finally:
            sender.cancel()
            await asyncio.gather(sender, return_exceptions=True)

    assert normalized(transcript) == normalized(TEXT), f"Transcript mismatch for {voice}: {transcript!r}; audio_bytes={len(pcm)}; events={dict(events)}"
    samples = array.array("h", pcm)
    if sys.byteorder != "little": samples.byteswap()
    audible = [i for i, x in enumerate(samples) if abs(x) > 220]
    assert audible, "No audible speech"
    start, end = max(0, audible[0] - 4800), min(len(samples), audible[-1] + 8400)
    pcm = pcm[start * 2:end * 2]
    seconds = len(pcm) / 48000
    assert 5 < seconds < 30, f"Unexpected sample duration: {seconds}"
    path = directory / (voice + ".wav")
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1); output.setsampwidth(2); output.setframerate(24000); output.writeframes(pcm)
    return {"voice": voice, "file": path.name, "seconds": round(seconds, 3),
            "transcript": transcript, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--voice", choices=VOICES, action="append")
    parser.add_argument("--output", type=pathlib.Path, default=pathlib.Path("Resources/VoicePreviews"))
    args = parser.parse_args()
    key = os.environ.get("OPENAI_API_KEY")
    if not key: raise SystemExit("Set OPENAI_API_KEY in this process environment; the script does not save credentials.")
    args.output.mkdir(parents=True, exist_ok=True)
    manifest_path = args.output / "manifest.json"
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {
        "model": "gpt-live-1", "text": TEXT, "samples": [],
        "description": "AI-generated bilingual preview clips; synthetic text only. No microphone capture. store=false.",
    }
    try:
        for voice in args.voice or VOICES:
            result = await render(voice, key, args.output)
            manifest["samples"] = [x for x in manifest["samples"] if x["voice"] != voice] + [result]
            manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
            print(voice, result["seconds"], "seconds; transcript verified", flush=True)
    except Exception as error:
        raise SystemExit(str(error).replace(key, "[redacted]")) from None


if __name__ == "__main__":
    asyncio.run(main())
