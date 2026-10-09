#!/usr/bin/env python3
"""Synthesize coin SFX locally (no API needed).

Same local-synthesis pattern as generate_dice_contact_sfx.py (whose helpers
it imports): additive synthesis + a filtered-noise transient -> WAV ->
afconvert (AAC) -> m4a into Sources/App/Resources/SFX/.

Why these exist: no existing sample reads as METAL on METAL. chip_place /
chip_pass are soft chip-on-felt sounds and the dice bank is bone/wood. The
coin simulation (Sources/App/Dice/Coins) needs:

- coin_clink_1/2/3: a bright metallic ping, three takes at different base
  pitch. Inharmonic partials (ratios ~1 : 1.52 : 2.31 : 3.17, the
  signature of a struck metal disc) with fast, partial-dependent decay and
  a ~3 ms highpassed-noise transient. TableSFX.playCoinClink layers a felt
  thud (the existing dice_felt_thud) under hard hits.
- coin_spin_down: the classic dropped-coin whirr. A train of short pings
  whose spacing shrinks exponentially (90 ms down to ~5 ms, where the
  pings fuse into a buzz) under a decaying envelope, finishing with two
  quick settle ticks. ~1.1 s, matched to CoinEdgeState.fallDuration (0.95 s).

Usage: python3 tools/generate_coin_sfx.py
"""
import math
import os
import random
import sys

sys.path.insert(0, os.path.dirname(__file__))
from generate_dice_contact_sfx import (  # noqa: E402
    RATE, OUT_DIR, box_lowpass, noise_burst, normalize_and_write)

RATIOS = [1.0, 1.52, 2.31, 3.17]
AMPS = [1.0, 0.6, 0.35, 0.18]
DECAYS = [14.0, 22.0, 32.0, 48.0]


def add_ping(samples, start, base, scale=1.0, length=0.35, decay_mul=1.0):
    n0 = int(start * RATE)
    n = min(len(samples) - n0, int(length * RATE))
    if n <= 0:
        return
    for r, a, d in zip(RATIOS, AMPS, DECAYS):
        w = 2 * math.pi * base * r / RATE
        dec = d * decay_mul / RATE
        for i in range(n):
            samples[n0 + i] += scale * a * math.exp(-dec * i) * math.sin(w * i)
    # Strike transient: ~3 ms of highpassed noise.
    rng = random.Random(int(start * 1e6) + int(base))
    tn = int(0.003 * RATE)
    prev = 0.0
    for i in range(min(tn, n)):
        x = rng.uniform(-1, 1)
        hp = x - prev
        prev = x
        samples[n0 + i] += scale * 0.5 * hp * (1 - i / tn)


def make_clink(path, base, seed):
    random.seed(seed)
    duration = 0.38
    samples = [0.0] * int(duration * RATE)
    add_ping(samples, 0.0, base, 1.0, length=duration)
    # Faint low body so it isn't pure glass.
    body = noise_burst(0.06, 70, seed)
    body = box_lowpass(body, passes=3, window=28)
    for i in range(min(len(body), len(samples))):
        samples[i] += body[i] * 0.25
    normalize_and_write(samples, path, peak_target=0.7)


def make_spin_down(path):
    duration = 1.2
    samples = [0.0] * int(duration * RATE)
    t = 0.0
    interval = 0.09
    spin_len = 0.95
    k = 0
    while t < spin_len:
        env = (1 - t / spin_len) ** 0.5
        base = 2900 + 120 * math.sin(k * 1.7)
        # Pings fuse into a buzz as the interval shrinks; keep them short.
        add_ping(samples, t, base, scale=0.55 * env + 0.1, length=0.07, decay_mul=2.2)
        interval = max(0.0045, interval * 0.93)
        t += interval
        k += 1
    # Two quick settle ticks as the coin finally lies flat.
    add_ping(samples, 0.98, 3300, 0.5, length=0.09, decay_mul=2.5)
    add_ping(samples, 1.03, 3100, 0.3, length=0.08, decay_mul=2.8)
    normalize_and_write(samples, path, peak_target=0.65)


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    jobs = {
        "coin_clink_1": lambda p: make_clink(p, 2600, 11),
        "coin_clink_2": lambda p: make_clink(p, 3050, 22),
        "coin_clink_3": lambda p: make_clink(p, 3500, 33),
        "coin_spin_down": make_spin_down,
    }
    for name, fn in jobs.items():
        path = os.path.join(OUT_DIR, f"{name}.m4a")
        fn(path)
        print("wrote", os.path.normpath(path))


if __name__ == "__main__":
    main()
