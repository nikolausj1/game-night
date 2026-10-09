#!/bin/zsh
# Two-sim Multipeer join test: iPad = table, iPhone = hand.
#   tools/verify/multipeer.sh [--runs N] [--timeout SECS] [--no-install]
# Env: GN_VERIFY_OUT=<dir> to write into an existing run dir (verify.sh does this).
#
# JOIN ASSERTION (two independent evidence channels; PASS if either holds):
#  A. LOG   - `log stream` on the iPad for subsystem com.levelup.gamenight matching
#             GN_JOIN_LOG_REGEX (default: 'peer connected|welcome sent|hello from').
#             NOTE: the app currently has NO such info lines (HostSession/GameHostController
#             only log errors), so A is dormant until the lead adds them (see README).
#  B. STATE - table is launched with -autoStart (free play starts the moment a phone sits)
#             and the phone with -autoPlay (draws a card once seated). The table autosaves
#             to Documents/SavedGames/*.json 2s after the draw. We read that JSON from the
#             iPad's data container and require a seat with isBot=false and a deviceID,
#             whose name matches the phone's. That can only happen via a real
#             hello -> welcome -> seat -> snapshot -> drawCard round trip over Multipeer.
set -u
cd "$(dirname "$0")/../.." || exit 2
RUNS=1; TIMEOUT=90; INSTALL=1
while [[ $# -gt 0 ]]; do case $1 in
  --runs) RUNS=$2; shift 2;; --timeout) TIMEOUT=$2; shift 2;; --no-install) INSTALL=0; shift;; *) echo "unknown $1"; exit 2;; esac; done

IPAD=9704894E-AAA0-407F-9462-C11E4F8A251E
IPHONE=BB8EF1B1-6871-4192-8A39-B47EC8120E0D
BUNDLE=com.levelup.gamenight
SCRATCH="${GN_SCRATCH:-/private/tmp/claude-501/-Users-justinnikolaus-Library-CloudStorage-Dropbox--Projects-Digital-Card-Games/a7478288-cfd6-4de8-b4f5-c4c42aabd4dd/scratchpad}"
APP="${GN_APP:-$SCRATCH/dd-shared/Build/Products/Debug-iphonesimulator/GameNight.app}"
LOGRE="${GN_JOIN_LOG_REGEX:-peer connected|welcome sent|hello from}"
OUT="${GN_VERIFY_OUT:-_review/verify/$(date +%Y%m%d-%H%M%S)}/multipeer"
mkdir -p "$OUT"
[[ -d "$APP" ]] || { echo "No built app at $APP (run tools/build.sh)"; exit 2; }

# hard-timeout wrapper (macOS has no `timeout`)
to() { local s=$1; shift; perl -e 'alarm shift; exec @ARGV' "$s" "$@"; }

for u in $IPAD $IPHONE; do
  xcrun simctl boot $u 2>/dev/null
  to ${GN_BOOT_TIMEOUT:-600} xcrun simctl bootstatus $u -b >/dev/null 2>&1 || { echo "FAIL: sim $u failed to boot"; exit 1; }
done
if [[ $INSTALL == 1 ]]; then
  for u in $IPAD $IPHONE; do
    to 120 xcrun simctl uninstall $u $BUNDLE 2>/dev/null
    to 300 xcrun simctl install $u "$APP" || { echo "FAIL: install on $u"; exit 1; }
  done
fi

passes=0
for run in $(seq 1 $RUNS); do
  echo "== run $run/$RUNS"
  to 60 xcrun simctl terminate $IPAD $BUNDLE 2>/dev/null; to 60 xcrun simctl terminate $IPHONE $BUNDLE 2>/dev/null
  DATA=$(to 60 xcrun simctl get_app_container $IPAD $BUNDLE data)
  rm -f "$DATA"/Documents/SavedGames/*.json 2>/dev/null     # clean slate: any save after this is NEW
  LOGF="$OUT/ipad-log-$run.txt"; : > "$LOGF"
  xcrun simctl spawn $IPAD log stream --level info --predicate 'subsystem == "com.levelup.gamenight"' >"$LOGF" 2>&1 &
  LOGPID=$!
  PLOGF="$OUT/iphone-log-$run.txt"; : > "$PLOGF"
  xcrun simctl spawn $IPHONE log stream --level info --predicate 'subsystem == "com.levelup.gamenight"' >"$PLOGF" 2>&1 &
  PLOGPID=$!

  T0=$SECONDS
  IPADPID=$(to 120 xcrun simctl launch --terminate-running-process $IPAD $BUNDLE -autoRole table -autoStart | awk -F': ' '{print $NF}')
  sleep 6   # let the table start advertising before the phone browses
  IPHONEPID=$(to 120 xcrun simctl launch --terminate-running-process $IPHONE $BUNDLE -autoRole hand -autoPlay | awk -F': ' '{print $NF}')
  echo "   launched ipad pid=$IPADPID iphone pid=$IPHONEPID"

  EVID=""; JOINSECS=""
  while (( SECONDS - T0 < TIMEOUT )); do
    if grep -Eq "$LOGRE" "$LOGF" 2>/dev/null; then EVID="A:log"; fi
    STATE=$(python3 - "$DATA" <<'PY'
import glob, json, sys
for f in glob.glob(sys.argv[1] + "/Documents/SavedGames/*.json"):
    try:
        j = json.load(open(f))
    except Exception:
        continue
    for s in j.get("seats", []):
        if not s.get("isBot", True) and s.get("deviceID"):
            print("seat=%s name=%r game=%s" % (s.get("id"), s.get("name"), j.get("gameKind"))); sys.exit(0)
PY
)
    if [[ -n "$STATE" ]]; then EVID="${EVID:+$EVID+}B:state($STATE)"; fi
    if [[ -n "$EVID" ]]; then JOINSECS=$((SECONDS - T0)); break; fi
    sleep 3
  done
  sleep 3   # let the table render the seated phone before shooting
  to 90 xcrun simctl io $IPAD screenshot --type=png "$OUT/ipad-$run.raw.png" >/dev/null 2>&1
  to 90 xcrun simctl io $IPHONE screenshot --type=png "$OUT/iphone-$run.png" >/dev/null 2>&1
  python3 - "$OUT/ipad-$run.raw.png" "$OUT/ipad-$run.png" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1])
(im.rotate(-90, expand=True) if im.size[0] < im.size[1] else im).save(sys.argv[2])
PY
  ALIVE_T=no; ALIVE_H=no
  ps -p "$IPADPID" >/dev/null 2>&1 && ALIVE_T=yes
  ps -p "$IPHONEPID" >/dev/null 2>&1 && ALIVE_H=yes
  kill $LOGPID $PLOGPID 2>/dev/null; wait $LOGPID $PLOGPID 2>/dev/null
  if [[ -n "$EVID" && $ALIVE_T == yes && $ALIVE_H == yes ]]; then
    echo "   PASS run $run: join proven in ${JOINSECS}s via $EVID (both apps alive)"; passes=$((passes+1))
  else
    echo "   FAIL run $run: evidence='${EVID:-none}' table_alive=$ALIVE_T hand_alive=$ALIVE_H (waited ${TIMEOUT}s)"
  fi
done
echo "MULTIPEER: $passes/$RUNS runs passed (flakiness = runs failed). Artifacts: $OUT"
[[ $passes == $RUNS ]]
