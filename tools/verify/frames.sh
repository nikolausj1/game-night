#!/bin/zsh
# Motion proof: record the sim for N seconds and emit a filmstrip PNG.
#   tools/verify/frames.sh <udid> <seconds> <out.png> [frames=8] [launch args...]
# If launch args are given, the app is (re)launched with them right before recording.
# Env: FRAMES_ROTATE=auto|0|1 (default auto: rotate -90 when frames are portrait-framed AND the
#      sim is an iPad), FRAMES_HEIGHT=480 (strip height), FRAMES_KEEP=1 (keep the individual frames).
set -u
[[ $# -ge 3 ]] || { echo "usage: $0 <udid> <seconds> <out.png> [frames] [launch args...]"; exit 2; }
UDID=$1; SECS=$2; OUTPNG=$3; N=${4:-8}; shift 4 2>/dev/null || shift $#
HERE="$(cd "$(dirname "$0")" && pwd)"
BUNDLE=com.levelup.gamenight
to() { local s=$1; shift; perl -e 'alarm shift; exec @ARGV' "$s" "$@"; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gn-frames.XXXXXX")
if [[ $# -gt 0 ]]; then to 120 xcrun simctl launch --terminate-running-process $UDID $BUNDLE "$@" >/dev/null; sleep 2; fi
VID="$WORK/clip.mp4"
perl -e '$SIG{INT}="DEFAULT"; exec @ARGV' xcrun simctl io $UDID recordVideo --codec=h264 --force "$VID" >"$WORK/rec.log" 2>&1 &
REC=$!
sleep "$SECS"
kill -INT $REC 2>/dev/null
for i in {1..40}; do kill -0 $REC 2>/dev/null || break; sleep 0.5; done   # let it finalize the mp4
kill -KILL $REC 2>/dev/null
[[ -s "$VID" ]] || { echo "no video recorded:"; cat "$WORK/rec.log"; exit 1; }

mkdir -p "$WORK/f"
if command -v ffmpeg >/dev/null 2>&1; then
  DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$VID" 2>/dev/null)
  : ${DUR:=$SECS}
  for i in $(seq 1 $N); do
    T=$(python3 -c "d=float('$DUR');n=$N;print(0 if n==1 else round(d*0.98*($i-1)/(n-1),3))")
    ffmpeg -v error -y -ss "$T" -i "$VID" -frames:v 1 "$WORK/f/frame_$(printf %02d $i).png"
  done
else
  echo "ffmpeg missing - using AVFoundation fallback"
  swift "$HERE/extract_frames.swift" "$VID" "$WORK/f" $N
fi
FILES=("$WORK"/f/frame_*.png)
[[ -e "${FILES[1]}" ]] || { echo "frame extraction failed"; exit 1; }

ROT=${FRAMES_ROTATE:-auto}
if [[ $ROT == auto ]]; then
  NAME=$(xcrun simctl list devices | grep "$UDID" | head -1)
  [[ "$NAME" == *iPad* ]] && ROT=1 || ROT=0
fi
python3 - "$ROT" "${FILES[@]}" <<'PY'
import sys
from PIL import Image
rot, files = sys.argv[1], sys.argv[2:]
for f in files:
    im = Image.open(f)
    if rot == "1" and im.size[0] < im.size[1]:
        im.rotate(-90, expand=True).save(f)
PY
python3 "$HERE/hstack.py" "$OUTPNG" "${FRAMES_HEIGHT:-480}" "${FILES[@]}"
if [[ "${FRAMES_KEEP:-0}" == 1 ]]; then cp -R "$WORK/f" "${OUTPNG%.png}-frames"; fi
# motion check: consecutive frames should differ if anything is moving
python3 - "${FILES[@]}" <<'PY'
import sys
from PIL import Image, ImageChops, ImageStat
fs = [Image.open(f).convert("L").resize((96, 96)) for f in sys.argv[1:]]
d = [ImageStat.Stat(ImageChops.difference(a, b)).mean[0] for a, b in zip(fs, fs[1:])]
print("frame-to-frame mean diff: " + " ".join("%.1f" % x for x in d) + ("   (MOTION)" if max(d, default=0) > 1.0 else "   (STATIC - nothing moved)"))
PY
rm -rf "$WORK"
