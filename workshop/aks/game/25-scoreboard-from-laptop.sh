#!/usr/bin/env bash
# Run on your laptop after game-10-setup.sh: ./game/25-scoreboard-from-laptop.sh
# Runs the scoreboard on the jumpbox and forwards it to http://localhost:8088/
# for the projector. Ctrl-C stops both.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${GAME_SCOREBOARD_PORT:-8088}"
TARGET="$(terraform -chdir="$ROOT/landing-zone" output -raw jumpbox_ssh | awk '{print $2}')"

echo "Scoreboard: http://localhost:$PORT/"
if command -v open >/dev/null; then (sleep 5 && open "http://localhost:$PORT/") & fi
ssh -t -o ExitOnForwardFailure=yes -L "$PORT:127.0.0.1:$PORT" "$TARGET" \
  "GAME_SCOREBOARD_PORT=$PORT /opt/aks-ccc/game-20-scoreboard.sh"
