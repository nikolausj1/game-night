#!/usr/bin/env python3
"""Synthesize the soft watchdog chime locally (no API needed).

A gentle two-note bell (E6 then B5) with exponential decay and a couple of
soft inharmonic partials — the sound of the table politely finishing a
chore for an absent player. Writes a WAV then encodes to m4a (AAC) via
afconvert into `Sources/App/Resources/SFX/soft_chime.m4a` (folder
reference — lands in the bundle without xcodegen; TableSFX.resolvedURL
tries mp3 then m4a).

Usage: python3 tools/generate_soft_chime.py
"""
import math
import os
import struct
import subprocess
import tempfile
import wave

RATE = 44100
OUT = os.path.join(os.path.dirname(__file__), "..",
                   "Sources", "App", "Resources", "SFX", "soft_chime.m4a")


def bell(freq, start, dur, amp, samples):
    """Add one decaying bell strike into the sample buffer."""
    n0 = int(start * RATE)
    for i in range(int(dur * RATE)):
        t = i / RATE
        env = math.exp(-4.2 * t) * min(1.0, t / 0.004)  # fast attack, long tail
        v = (math.sin(2 * math.pi * freq * t)
             + 0.35 * math.sin(2 * math.pi * freq * 2.76 * t) * math.exp(-7 * t)
             + 0.18 * math.sin(2 * math.pi * freq * 5.40 * t) * math.exp(-11 * t))
        if n0 + i < len(samples):
            samples[n0 + i] += amp * env * v


def main():
    total = 1.4
    samples = [0.0] * int(total * RATE)
    bell(1318.5, 0.00, 1.2, 0.30, samples)   # E6
    bell(987.8, 0.18, 1.2, 0.26, samples)    # B5
    peak = max(abs(s) for s in samples) or 1.0
    scale = 0.7 / peak

    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        wav_path = tmp.name
    with wave.open(wav_path, "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(
            struct.pack("<h", int(max(-1, min(1, s * scale)) * 32767))
            for s in samples))

    subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", "-b", "96000",
                    wav_path, OUT], check=True)
    os.unlink(wav_path)
    print("wrote", os.path.normpath(OUT))


if __name__ == "__main__":
    main()
