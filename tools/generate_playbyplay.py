#!/usr/bin/env python3
"""Design-time live play-by-play clip generation (ElevenLabs) — see PRD §9.

Bounded, approved batch (~35 clips) that EXTENDS the ported Wizard Keeper
announcer corpus (`Sources/App/Resources/Announcer/charlie/`, copied over
verbatim — do NOT regenerate that corpus here) with new event families for
live table play: trick-win tails, trump reveal, bid callouts, over/underbid
color, and special-card callouts (wizard/jester/last-card).

Same voice/model/naming discipline as Wizard Keeper's
`tools/generate_announcer.py`: single voice "Charlie"
(IKne3meq5aSn9XLyUdCD), model eleven_multilingual_v2, flat `<category>_<i>`
or `<category>_<n>` basenames (no tone-tier bucketing — these lines are
tone-neutral color commentary, unlike the tail/leadin grammar's
Classic/Fun/Spicy buckets), written into the SAME `charlie/` folder as the
ported corpus.

Resumable: existing non-empty files are skipped. Merges a "playByPlay"
section into manifest.json (does not touch any other section) so the app
can enumerate what's on disk without a directory scan.

Usage: source ~/.secrets/api-keys.env && python3 tools/generate_playbyplay.py
"""
import json
import os
import sys
import time
import urllib.request

API_KEY = os.environ.get("ELEVENLABS_API_KEY")
if not API_KEY:
    sys.exit("ELEVENLABS_API_KEY not set — source ~/.secrets/api-keys.env")

OUT_ROOT = os.path.join(os.path.dirname(__file__), "..", "Sources", "App", "Resources", "Announcer")
VOICE_ID = "IKne3meq5aSn9XLyUdCD"  # Charlie — same voice as the ported corpus
VOICE_NAME = "charlie"
MODEL = "eleven_multilingual_v2"

BID_WORDS = {
    0: "Zero", 1: "One", 2: "Two", 3: "Three", 4: "Four", 5: "Five",
    6: "Six", 7: "Seven", 8: "Eight", 9: "Nine", 10: "Ten",
}

TRUMP_SUITS = ["hearts", "diamonds", "clubs", "spades"]

TAKES = [
    "takes it!", "sweeps the trick!", "snatches that one!",
    "wins the trick!", "takes it home!", "grabs it!",
]
OVERBID = ["Someone's going down!", "Not enough tricks to go around!", "Bold table!"]
UNDERBID = ["Playing it safe, are we?", "Somebody's ducking!", "Cowards, the lot of you!"]
WIZARD_PLAYED = ["A wizard!", "The wizard comes out!", "Wizard on the table!"]
JESTER_PLAYED = ["A jester!", "The fool appears!"]
LAST_CARD = ["Last card!", "Down to one!"]


def tts(text, path):
    body = json.dumps({
        "text": text, "model_id": MODEL,
        "voice_settings": {"stability": 0.35, "similarity_boost": 0.75, "style": 0.65},
    }).encode()
    req = urllib.request.Request(
        f"https://api.elevenlabs.io/v1/text-to-speech/{VOICE_ID}?output_format=mp3_44100_128",
        data=body, headers={"xi-api-key": API_KEY, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        data = resp.read()
    if not data.startswith(b"ID3") and data[:1] != b"\xff":
        raise RuntimeError(f"non-audio response: {data[:120]!r}")
    with open(path, "wb") as f:
        f.write(data)


def jobs():
    out = []  # (filename, spoken text) — generation order = priority order
    for i, line in enumerate(TAKES):
        out.append((f"takes_{i}.mp3", line))
    for suit in TRUMP_SUITS:
        out.append((f"trump_{suit}.mp3", f"Trump is {suit}!"))
    out.append(("trump_none.mp3", "No trump this round!"))
    for n, word in BID_WORDS.items():
        out.append((f"bids_{n}.mp3", f"Bids {word.lower()}!"))
    for i, line in enumerate(OVERBID):
        out.append((f"overbid_{i}.mp3", line))
    for i, line in enumerate(UNDERBID):
        out.append((f"underbid_{i}.mp3", line))
    for i, line in enumerate(WIZARD_PLAYED):
        out.append((f"wizardplayed_{i}.mp3", line))
    for i, line in enumerate(JESTER_PLAYED):
        out.append((f"jesterplayed_{i}.mp3", line))
    for i, line in enumerate(LAST_CARD):
        out.append((f"lastcard_{i}.mp3", line))
    return out


def merge_manifest(counts):
    manifest_path = os.path.join(OUT_ROOT, "manifest.json")
    manifest = {}
    if os.path.exists(manifest_path):
        with open(manifest_path) as f:
            manifest = json.load(f)
    manifest["playByPlay"] = {
        "takes": counts.get("takes", len(TAKES)),
        "trump": TRUMP_SUITS,
        "bids": [min(BID_WORDS), max(BID_WORDS)],
        "overbid": counts.get("overbid", len(OVERBID)),
        "underbid": counts.get("underbid", len(UNDERBID)),
        "wizardPlayed": counts.get("wizardplayed", len(WIZARD_PLAYED)),
        "jesterPlayed": counts.get("jesterplayed", len(JESTER_PLAYED)),
        "lastCard": counts.get("lastcard", len(LAST_CARD)),
    }
    with open(manifest_path, "w") as f:
        json.dump(manifest, f, indent=1)


def main():
    vdir = os.path.join(OUT_ROOT, VOICE_NAME)
    os.makedirs(vdir, exist_ok=True)

    all_jobs = jobs()
    total_chars = sum(len(text) for _, text in all_jobs)
    print(f"playByPlay: {len(all_jobs)} clips queued, {total_chars} characters total", flush=True)

    done = skipped = failed = 0
    missing = []
    for fname, text in all_jobs:
        path = os.path.join(vdir, fname)
        if os.path.exists(path) and os.path.getsize(path) > 1000:
            skipped += 1
            continue
        ok = False
        for attempt in (1, 2):
            try:
                tts(text, path)
                done += 1
                ok = True
                break
            except Exception as e:
                if attempt == 2:
                    failed += 1
                    missing.append(fname)
                    print(f"FAIL {fname}: {e}", flush=True)
                else:
                    time.sleep(3)
        if not ok and not os.path.exists(path):
            pass
        time.sleep(0.35)  # gentle on rate limits

    # Present on-disk counts per category (post-run), so the manifest
    # reflects reality even on a partial/failed run — same resumable
    # discipline as tools/generate_announcer.py.
    def count_prefix(prefix, indices):
        c = 0
        for i in indices:
            if os.path.exists(os.path.join(vdir, f"{prefix}_{i}.mp3")):
                c += 1
            else:
                break
        return c

    counts = {
        "takes": count_prefix("takes", range(len(TAKES))),
        "overbid": count_prefix("overbid", range(len(OVERBID))),
        "underbid": count_prefix("underbid", range(len(UNDERBID))),
        "wizardplayed": count_prefix("wizardplayed", range(len(WIZARD_PLAYED))),
        "jesterplayed": count_prefix("jesterplayed", range(len(JESTER_PLAYED))),
        "lastcard": count_prefix("lastcard", range(len(LAST_CARD))),
    }
    merge_manifest(counts)

    print(f"DONE: {done} generated, {skipped} skipped, {failed} failed", flush=True)
    if missing:
        print("MISSING (rely on Announcer's graceful skip): " + ", ".join(missing), flush=True)


if __name__ == "__main__":
    main()
