#!/usr/bin/env python3
"""Design-time table SFX generation (ElevenLabs sound-generation) — see PRD §9.

Generates 8 short (1-3s) ambient table sound effects via ElevenLabs'
`/v1/sound-generation` endpoint (text-to-sound-effect, NOT text-to-speech —
no voice ID involved) into `Sources/App/Resources/SFX/`. Paired with
`Sources/App/Announcer/TableSFX.swift`, which preloads and plays these.

Resumable: existing non-empty files are skipped. Merges an "sfx" section
into manifest.json (does not touch any other section).

Usage: source ~/.secrets/api-keys.env && python3 tools/generate_sfx.py
"""
import json
import os
import sys
import time
import urllib.request

API_KEY = os.environ.get("ELEVENLABS_API_KEY")
if not API_KEY:
    sys.exit("ELEVENLABS_API_KEY not set — source ~/.secrets/api-keys.env")

OUT_ROOT = os.path.join(os.path.dirname(__file__), "..", "Sources", "App", "Resources", "SFX")
ANNOUNCER_MANIFEST = os.path.join(
    os.path.dirname(__file__), "..", "Sources", "App", "Resources", "Announcer", "manifest.json"
)

# name -> (prompt, duration_seconds)
EFFECTS = {
    "card_slide": ("A single playing card sliding quickly across a wooden table surface, close mic, no music", 1.0),
    "card_flip": ("A single playing card being flipped and landing flat on a table, crisp snap, close mic", 0.6),
    "card_deal": ("Rapid multi-card deal, several playing cards snapping down onto a table one after another in quick succession, close mic, no music", 2.0),
    "shuffle": ("A deck of playing cards being riffle-shuffled by hand, crisp paper flutter, close mic, no music", 2.0),
    "trick_sweep": ("A small pile of playing cards being swept and gathered across a table surface in one smooth motion, close mic, no music", 1.2),
    "chip_place": ("A single poker chip being placed down onto a table with a light clack, close mic, no music", 0.6),
    "table_knock": ("A single knuckle knock on a wooden table, short and dry, close mic, no music", 0.5),
    "fanfare_win": ("A short, cheerful, triumphant tabletop-game victory fanfare, a few bright notes, no vocals, no drums, celebratory but brief", 2.5),
}


def generate_sfx(text, duration_seconds, path):
    body = json.dumps({
        "text": text,
        "duration_seconds": duration_seconds,
        "prompt_influence": 0.4,
    }).encode()
    req = urllib.request.Request(
        "https://api.elevenlabs.io/v1/sound-generation",
        data=body, headers={"xi-api-key": API_KEY, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=90) as resp:
        data = resp.read()
    if not data.startswith(b"ID3") and data[:1] != b"\xff":
        raise RuntimeError(f"non-audio response: {data[:120]!r}")
    with open(path, "wb") as f:
        f.write(data)


def merge_manifest(present):
    manifest = {}
    if os.path.exists(ANNOUNCER_MANIFEST):
        with open(ANNOUNCER_MANIFEST) as f:
            manifest = json.load(f)
    manifest["sfx"] = present
    with open(ANNOUNCER_MANIFEST, "w") as f:
        json.dump(manifest, f, indent=1)


def main():
    os.makedirs(OUT_ROOT, exist_ok=True)

    total_chars = sum(len(prompt) for prompt, _ in EFFECTS.values())
    print(f"sfx: {len(EFFECTS)} effects queued, {total_chars} prompt characters total", flush=True)

    done = skipped = failed = 0
    missing = []
    for name, (prompt, duration) in EFFECTS.items():
        path = os.path.join(OUT_ROOT, f"{name}.mp3")
        if os.path.exists(path) and os.path.getsize(path) > 1000:
            skipped += 1
            continue
        for attempt in (1, 2):
            try:
                generate_sfx(prompt, duration, path)
                done += 1
                break
            except Exception as e:
                if attempt == 2:
                    failed += 1
                    missing.append(name)
                    print(f"FAIL {name}: {e}", flush=True)
                else:
                    time.sleep(3)
        time.sleep(0.5)

    present = [name for name in EFFECTS if os.path.exists(os.path.join(OUT_ROOT, f"{name}.mp3"))]
    merge_manifest(present)

    print(f"DONE: {done} generated, {skipped} skipped, {failed} failed", flush=True)
    if missing:
        print("MISSING (rely on TableSFX's graceful skip): " + ", ".join(missing), flush=True)


if __name__ == "__main__":
    main()
