#!/usr/bin/env python3
"""Design-time dice SFX generation (ElevenLabs sound-generation).

Same pattern as tools/generate_sfx.py: 5 short effects for dice mode via
`/v1/sound-generation` into `Sources/App/Resources/SFX/` (folder reference
— lands in the bundle without xcodegen). The three rattle variants are
played PHONE-side by DiceCupView's CupAudio pool (dice knocking inside the
cup as you shake); dice_pour and chip_pass are table-side via TableSFX.

Resumable: existing non-empty files are skipped. Merges the new names into
manifest.json's "sfx" list (preserving whatever is already there).

Usage: source ~/.secrets/api-keys.env && python3 tools/generate_dice_sfx.py
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
    "dice_rattle_1": ("Two or three small dice rattling once inside a leather dice cup, a single short shake, close mic, no music", 0.6),
    "dice_rattle_2": ("A quick sharp rattle of dice knocking against the inside walls of a leather cup, one jolt, close mic, no music", 0.6),
    "dice_rattle_3": ("Small dice clacking together inside a hand-held cup during one brisk shake, short and dry, close mic, no music", 0.7),
    "dice_pour": ("A few dice spilling out of a cup and tumbling across a felt card table, bouncing and settling, close mic, no music", 1.6),
    "chip_pass": ("A single small poker chip sliding briskly across felt and clicking against another chip, close mic, no music", 0.8),
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


def merge_manifest(new_present):
    manifest = {}
    if os.path.exists(ANNOUNCER_MANIFEST):
        with open(ANNOUNCER_MANIFEST) as f:
            manifest = json.load(f)
    existing = manifest.get("sfx", [])
    manifest["sfx"] = existing + [n for n in new_present if n not in existing]
    with open(ANNOUNCER_MANIFEST, "w") as f:
        json.dump(manifest, f, indent=1)


def main():
    os.makedirs(OUT_ROOT, exist_ok=True)

    total_chars = sum(len(prompt) for prompt, _ in EFFECTS.values())
    print(f"dice sfx: {len(EFFECTS)} effects queued, {total_chars} prompt characters total", flush=True)

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
        print("MISSING (TableSFX/CupAudio gracefully skip): " + ", ".join(missing), flush=True)


if __name__ == "__main__":
    main()
