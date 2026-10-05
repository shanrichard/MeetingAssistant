#!/usr/bin/env python3
"""Validate every bundled sample before packaging; no network or credentials."""
import array
import hashlib
import json
import pathlib
import re
import sys
import wave

root = pathlib.Path(__file__).resolve().parent.parent
source = (root / "Sources/MeetingCore/InterpreterVoice.swift").read_text()
voices = {voice.strip() for cases in re.findall(r"^\s*case ([\w, ]+)$", source, re.M) for voice in cases.split(",")}
folder = root / "Resources/VoicePreviews"
manifest = json.loads((folder / "manifest.json").read_text())
samples = manifest["samples"]
assert voices and {x["voice"] for x in samples} == voices and len(samples) == len(voices)
assert {x.stem for x in folder.glob("*.wav")} == voices
assert manifest["model"] == "gpt-live-1"
normalize = lambda text: "".join(c.lower() for c in text if c.isalnum())
hashes = set()
for sample in samples:
    path = folder / (sample["voice"] + ".wav")
    assert sample["file"] == path.name
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    assert digest == sample["sha256"] and digest not in hashes
    hashes.add(digest)
    assert normalize(sample["transcript"]) == normalize(manifest["text"])
    with wave.open(str(path)) as audio:
        assert (audio.getnchannels(), audio.getsampwidth(), audio.getframerate(), audio.getcomptype()) == (1, 2, 24000, "NONE")
        duration = audio.getnframes() / audio.getframerate()
        assert 5 < duration < 30 and abs(duration - sample["seconds"]) < 0.001
        pcm = array.array("h", audio.readframes(audio.getnframes()))
        if sys.byteorder != "little": pcm.byteswap()
        assert sum(x * x for x in pcm) / len(pcm) > 100 ** 2, "Sample is silent or too quiet"
print(f"Voice previews: {len(voices)}/{len(voices)} files, hashes, transcripts, formats and audible levels verified")
