#!/bin/zsh
# Serialized, shared build for parallel worker sessions.
#
# Why: ten concurrent xcodebuilds each with their own DerivedData blew the
# disk during the overnight build (2026-08-07). This script takes a lock
# (atomic mkdir) and builds into ONE shared DerivedData, so builds queue
# instead of colliding and incremental builds stay fast. Workers MUST use
# this instead of calling xcodebuild directly.
#
# Usage: tools/build.sh [sim|device]      (default: sim)
# Output: last 'error:' lines + BUILD SUCCEEDED/FAILED; exit code mirrors xcodebuild.
set -u
# LIVE REPO ONLY. Workers must never copy the repo and build the copy —
# each copy's build is another multi-GB DerivedData on a nearly full disk
# (it happened: two scratch copies ran concurrent builds and took free
# space from 8 GB to 3 GB in ten minutes). The DerivedData path below is
# FIXED and shared; GN_SCRATCH overrides are ignored on purpose.
LIVE="/Users/justinnikolaus/_Developer/Digital Card Games"
HERE="$(cd "$(dirname "$0")/.." && pwd -P)"
if [[ "$HERE" != "$LIVE" ]]; then
  echo "build.sh: refusing to build from '$HERE'."
  echo "build.sh: build the LIVE repo only: cd \"$LIVE\" && tools/build.sh"
  echo "build.sh: do not copy the repo; edit your owned files in place and verify there."
  exit 3
fi
cd "$LIVE"
TARGET="${1:-sim}"
# Disk guard: an ENOSPC mid-build corrupts the shared DerivedData for
# every worker. Below 1.5 GB free, stop and say so instead.
FREE_KB=$(df -k "$HOME" | awk 'NR==2 {print $4}')
if (( FREE_KB < 1500000 )); then
  echo "build.sh: only $((FREE_KB/1024)) MB free — refusing to build. Free disk first (scratch copies, old DerivedData)."
  exit 4
fi
SCRATCH="/private/tmp/claude-501/-Users-justinnikolaus-Library-CloudStorage-Dropbox--Projects-Digital-Card-Games/a7478288-cfd6-4de8-b4f5-c4c42aabd4dd/scratchpad"
DD="$SCRATCH/dd-shared"
LOCK="$SCRATCH/build.lock"
mkdir -p "$SCRATCH"
# Wait for the lock (max ~30 min), then take it. The lock records its
# holder's PID; a waiter that finds the holder dead (a worker's shell was
# killed mid-build, which leaves no chance for the EXIT trap) breaks the
# lock instead of queuing forever behind a ghost.
for i in {1..360}; do
  if mkdir "$LOCK" 2>/dev/null; then echo $$ > "$LOCK/pid"; break; fi
  holder=$(cat "$LOCK/pid" 2>/dev/null)
  if [[ -n "$holder" ]] && ! kill -0 "$holder" 2>/dev/null; then
    echo "build.sh: breaking stale lock (holder $holder is gone)"
    rm -rf "$LOCK"; continue
  fi
  if [[ -z "$holder" && -d "$LOCK" ]]; then
    # Legacy lock with no pid file: stale if older than 25 minutes.
    if [[ -n "$(find "$LOCK" -maxdepth 0 -mmin +25 2>/dev/null)" ]]; then
      echo "build.sh: breaking stale legacy lock"; rm -rf "$LOCK"; continue
    fi
  fi
  sleep 5
  if [[ $i -eq 360 ]]; then echo "build.sh: timed out waiting for lock"; exit 2; fi
done
trap 'rm -rf "$LOCK" 2>/dev/null' EXIT INT TERM HUP
# Regenerate the project only when the file set changed (new files = new xcodeproj).
xcodegen generate >/dev/null 2>&1
if [[ "$TARGET" == "device" ]]; then
  DEST='generic/platform=iOS'; EXTRA=(-allowProvisioningUpdates)
else
  DEST='generic/platform=iOS Simulator'; EXTRA=()
fi
LOG="$SCRATCH/build-$$.log"
xcodebuild -project GameNight.xcodeproj -scheme GameNight -destination "$DEST" \
  -derivedDataPath "$DD" "${EXTRA[@]}" build >"$LOG" 2>&1
STATUS=$?
grep -E "error:" "$LOG" | sort -u | head -40
grep -E "BUILD (SUCCEEDED|FAILED)" "$LOG" | tail -1
rm -f "$LOG"
exit $STATUS
