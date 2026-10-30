#!/usr/bin/env bash
# Run ON THE JUMPBOX after game-10-setup.sh: /opt/aks-ccc/game-20-scoreboard.sh
# Rebuilds the scoreboard every GAME_REFRESH_SECONDS (default 15) and serves it on
# 127.0.0.1:GAME_SCOREBOARD_PORT (default 8088) until Ctrl-C. View it through an
# SSH tunnel: workshop/aks/game/25-scoreboard-from-laptop.sh does both.
set -euo pipefail
GAME_DIR="${GAME_DIR:-$HOME/ccc-game}"
PORT="${GAME_SCOREBOARD_PORT:-8088}"
REFRESH="${GAME_REFRESH_SECONDS:-15}"

[[ -f "$GAME_DIR/game.json" ]] || { echo "$GAME_DIR/game.json not found. Run /opt/aks-ccc/game-10-setup.sh first."; exit 1; }
mkdir -p "$GAME_DIR/scoreboard"
python3 /opt/aks-ccc/game-scoreboard.py --game-dir "$GAME_DIR"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$GAME_DIR/scoreboard" >/dev/null 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null' EXIT
echo "Scoreboard on http://127.0.0.1:$PORT/ (refreshing every ${REFRESH}s, Ctrl-C to stop)"
while sleep "$REFRESH"; do
  python3 /opt/aks-ccc/game-scoreboard.py --game-dir "$GAME_DIR" || echo "Scoreboard update failed; retrying"
done
