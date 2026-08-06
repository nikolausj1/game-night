#!/usr/bin/env python3
"""Synthesize dice-contact impact SFX locally (no API needed).

Same local-synthesis pattern as generate_soft_chime.py: pure-Python additive
synthesis + filtered noise -> WAV -> afconvert (AAC) -> m4a into
Sources/App/Resources/SFX/. No network, so it's a fine fit for a sandboxed
worker session.

Why these three exist: the dice-contact throttle used to play ONE sample
(table_knock) for every collision regardless of what hit what — felt, bone,
or rail all sounded identical ("machine gun of the same knock", per the
sound-design audit). die-on-die contacts already had good raw material
(dice_rattle_1/2/3 — real dice knocking together), but there was nothing
that read as "soft dull thud on felt" or "woodier knock on the rail", so
those two get purpose-built samples here. A third, very quiet "settle tick"
covers the moment an individual die stops tumbling.

- dice_felt_thud:   heavily low-passed noise burst + a low sine partial.
                    No bright transient — felt kills it, so this stays
                    dull and dark even at full synthesized volume (the
                    velocity-mapped curve in TableSFX takes care of the
                    quiet-to-loud range at playback time).
- dice_rail_knock:  a brighter noise transient (lighter low-pass) plus two
                    inharmonic sine partials — reads as a hollow wood-rail
                    knock, brighter and more resonant than the felt thud.
- dice_settle_tick: very short, very quiet, higher-pitched — the last
                    little click as a die stops moving.

Usage: python3 tools/generate_dice_contact_sfx.py
"""
import math
import os
import random
import struct
import subprocess
import tempfile
import wave

RATE = 44100
OUT_DIR = os.path.join(os.path.dirname(__file__), "..",
                       "Sources", "App", "Resources", "SFX")


def box_lowpass(samples, passes, window):
    """A few passes of a small box filter = a cheap, dependency-free
    approximation of a gentle low-pass (no numpy/scipy in this repo's
    toolchain — same constraint generate_soft_chime.py works under)."""
    out = samples
    half = window // 2
    for _ in range(passes):
        filtered = [0.0] * len(out)
        acc = 0.0
        # Running-sum box filter — O(n) per pass instead of O(n*window).
        for i in range(len(out)):
            acc += out[i]
            if i - window >= 0:
                acc -= out[i - window]
            lo = max(0, i - half)
            hi = min(len(out) - 1, i + half)
            filtered[i] = acc / window if i >= window - 1 else out[i]
            _ = (lo, hi)
        out = filtered
    return out


def noise_burst(duration, decay_rate, seed):
    rng = random.Random(seed)
    n = int(duration * RATE)
    return [rng.uniform(-1, 1) * math.exp(-decay_rate * (i / RATE)) for i in range(n)]


def sine_partial(freq, duration, decay_rate, samples, amp=1.0, phase_offset=0.0):
    n = min(len(samples), int(duration * RATE))
    for i in range(n):
        t = i / RATE
        samples[i] += amp * math.exp(-decay_rate * t) * math.sin(2 * math.pi * freq * t + phase_offset)


def normalize_and_write(samples, path, peak_target=0.75):
    peak = max((abs(s) for s in samples), default=1.0) or 1.0
    scale = peak_target / peak
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
                    wav_path, path], check=True)
    os.unlink(wav_path)


def make_felt_thud(path):
    """Dull, low, no bright transient — felt swallows the attack."""
    duration = 0.30
    n = int(duration * RATE)
    burst = noise_burst(duration, decay_rate=26, seed=101)
    burst = box_lowpass(burst, passes=4, window=48)  # heavy lowpass ~ dull
    samples = [0.0] * n
    for i in range(min(n, len(burst))):
        samples[i] = burst[i] * 0.55
    sine_partial(135, duration, decay_rate=22, samples=samples, amp=0.55)
    sine_partial(95, duration, decay_rate=30, samples=samples, amp=0.22)
    normalize_and_write(samples, path, peak_target=0.6)


def make_rail_knock(path):
    """Woodier: brighter transient, two inharmonic partials, more ring."""
    duration = 0.40
    n = int(duration * RATE)
    burst = noise_burst(duration, decay_rate=45, seed=202)
    burst = box_lowpass(burst, passes=2, window=14)  # lighter lowpass ~ brighter
    samples = [0.0] * n
    for i in range(min(n, len(burst))):
        samples[i] = burst[i] * 0.5
    sine_partial(520, duration, decay_rate=13, samples=samples, amp=0.42)
    sine_partial(1180, duration, decay_rate=17, samples=samples, amp=0.24)
    sine_partial(260, duration, decay_rate=9, samples=samples, amp=0.20)
    normalize_and_write(samples, path, peak_target=0.7)


def make_settle_tick(path):
    """Very short, very quiet, higher-pitched — the last little click."""
    duration = 0.14
    n = int(duration * RATE)
    burst = noise_burst(duration, decay_rate=90, seed=303)
    burst = box_lowpass(burst, passes=2, window=10)
    samples = [0.0] * n
    for i in range(min(n, len(burst))):
        samples[i] = burst[i] * 0.35
    sine_partial(950, duration, decay_rate=38, samples=samples, amp=0.30)
    normalize_and_write(samples, path, peak_target=0.4)


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    jobs = {
        "dice_felt_thud": make_felt_thud,
        "dice_rail_knock": make_rail_knock,
        "dice_settle_tick": make_settle_tick,
    }
    for name, fn in jobs.items():
        path = os.path.join(OUT_DIR, f"{name}.m4a")
        fn(path)
        print("wrote", os.path.normpath(path))


if __name__ == "__main__":
    main()
