#!/bin/zsh
# Game Night verification machine. Run before every deploy:
#   tools/build.sh && tools/verify.sh [--only a,b|group] [--device ipad|iphone]
#                                     [--no-install] [--wait-scale 2] [--multipeer]
# Output: _review/verify/<timestamp>/{index.html,REPORT.md,*.png}. See tools/verify/README.md.
cd "$(dirname "$0")/.." || exit 2
exec python3 tools/verify/verify.py "$@"
