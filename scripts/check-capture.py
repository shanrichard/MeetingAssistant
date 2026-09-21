#!/usr/bin/env python3
"""Run a separately signed capture diagnostic with a quiet synthetic system tone.

Usage: python3 scripts/check-capture.py PATH_TO_DIAGNOSTIC.app
The diagnostic uses temporary audio only, deletes it, and never calls APIs.
"""
import math
import pathlib
import struct
import subprocess
import sys
import tempfile
import wave

with tempfile.TemporaryDirectory(prefix="MeetingAudioFixture-") as folder:
    tone = pathlib.Path(folder) / "tone.wav"
    with wave.open(str(tone), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(24000)
        output.writeframes(b"".join(struct.pack("<h", int(400 * math.sin(2 * math.pi * 330 * i / 24000))) for i in range(24000 * 90)))
    player = subprocess.Popen(["/usr/bin/afplay", str(tone)])
    try:
        executable = pathlib.Path(sys.argv[1]) / "Contents/MacOS/MeetingAssistant"
        result = subprocess.run([str(executable)], timeout=100)
    finally:
        player.terminate()
        player.wait()
    sys.exit(result.returncode)
