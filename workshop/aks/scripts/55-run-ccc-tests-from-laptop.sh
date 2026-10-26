#!/usr/bin/env bash
# Run on your laptop after 40-setup-ccc-tests.sh ran on the jumpbox:
#   ./scripts/55-run-ccc-tests-from-laptop.sh
#
# CCC.K8S.CN01 checks that the API server is unreachable from an untrusted
# network. The jumpbox is inside the approved network, so this script runs the
# CCC reachability observer (modules/probes/reachability) here on your laptop,
# forwards it to the jumpbox through an SSH reverse tunnel, runs
# /opt/aks-ccc/50-run-ccc-tests.sh there, and copies the results to
# ccc-results/<UTC time>/ (gitignored).
#
# The observer binary is built for your OS on the jumpbox (no Go needed here).
# It listens on 127.0.0.1 only, accepts HMAC-signed requests with a per-run
# secret and only probes *.azmk8s.io on port 443.
# Optional: CCC_TAGS, CCC_DEBUG (passed to 50-run-ccc-tests.sh), REBUILD=1.
# CCC_TARGET=vanilla (set by workshop/aks-vanilla/scripts/55-run-ccc-tests-from-laptop.sh)
# tests the plain AVM cluster; CCC_RESULTS_DIR overrides where results are copied.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT=18080
OBSERVER=laptop-internet
CCC_TARGET="${CCC_TARGET:-aks}"
RESULTS="${CCC_RESULTS_DIR:-$ROOT/ccc-results}"
if [[ "$CCC_TARGET" == aks ]]; then
  REMOTE_WORK='~/ccc-tests' SETUP_HINT=/opt/aks-ccc/40-setup-ccc-tests.sh
else
  REMOTE_WORK="~/ccc-tests-$CCC_TARGET" SETUP_HINT="/opt/aks-ccc/$CCC_TARGET/40-setup-ccc-tests.sh"
fi

TARGET="$(terraform -chdir="$ROOT/landing-zone" output -raw jumpbox_ssh | awk '{print $2}')"
case "$(uname -s)/$(uname -m)" in
  Darwin/arm64) GOOS=darwin GOARCH=arm64 ;;
  Darwin/x86_64) GOOS=darwin GOARCH=amd64 ;;
  Linux/x86_64) GOOS=linux GOARCH=amd64 ;;
  Linux/aarch64 | Linux/arm64) GOOS=linux GOARCH=arm64 ;;
  *) echo "Unsupported laptop platform $(uname -s)/$(uname -m)"; exit 1 ;;
esac
BIN="$RESULTS/.bin/ccc-reachability-probe-$GOOS-$GOARCH"
mkdir -p "$RESULTS/.bin"
ssh "$TARGET" "test -f $REMOTE_WORK/ccc-test-env.sh" \
  || { echo "Setup has not completed on the jumpbox. Run $SETUP_HINT there first."; exit 1; }

if [[ ! -x "$BIN" || -n "${REBUILD:-}" ]]; then
  echo "==> Building the reachability observer for $GOOS/$GOARCH on the jumpbox"
  ssh "$TARGET" "set -e; source $REMOTE_WORK/ccc-test-env.sh; cd \"\$CCC_DIR/modules/probes/reachability\"
    GOWORK=off CGO_ENABLED=0 GOOS=$GOOS GOARCH=$GOARCH /usr/local/go/bin/go build -trimpath -o /tmp/ccc-reachability-probe ."
  scp -q "$TARGET:/tmp/ccc-reachability-probe" "$BIN"
  chmod +x "$BIN"
fi

SECRET="$(openssl rand -hex 32)"
ssh "$TARGET" "umask 077; cat > $REMOTE_WORK/reachability-secret" <<<"$SECRET"

echo "==> Starting the observer on 127.0.0.1:$PORT"
SHARED_SECRET="$SECRET" TARGET_ALLOWLIST='*.azmk8s.io' PORT_ALLOWLIST=443 OBSERVER_NAME="$OBSERVER" \
  LISTEN_ADDRESS="127.0.0.1:$PORT" "$BIN" > "$RESULTS/.bin/observer.log" 2>&1 &
OBSERVER_PID=$!
cleanup() {
  kill "$OBSERVER_PID" 2>/dev/null || true
  ssh "$TARGET" "rm -f $REMOTE_WORK/reachability-secret" || true
}
trap cleanup EXIT
sleep 1
curl -fsS -m 5 "http://127.0.0.1:$PORT/healthz" >/dev/null || { cat "$RESULTS/.bin/observer.log"; exit 1; }

echo "==> Running the tests on the jumpbox (tunnel: jumpbox 127.0.0.1:$PORT -> laptop observer)"
set +e
ssh -t -o ExitOnForwardFailure=yes -R "$PORT:127.0.0.1:$PORT" "$TARGET" \
  "CCC_TARGET='$CCC_TARGET' CCC_TAGS='${CCC_TAGS:-}' CCC_DEBUG='${CCC_DEBUG:-0}' /opt/aks-ccc/50-run-ccc-tests.sh"
rc=$?
set -e

LATEST="$(ssh "$TARGET" "readlink -f $REMOTE_WORK/results/latest" || true)"
if [[ -n "$LATEST" ]]; then
  scp -q -r "$TARGET:$LATEST" "$RESULTS/"
  DASHBOARD="$RESULTS/$(basename "$LATEST")/dashboard.html"
  echo "Results: $RESULTS/$(basename "$LATEST")"
  if [[ -f "$DASHBOARD" ]]; then
    echo "Dashboard: $DASHBOARD"
    command -v open >/dev/null && open "$DASHBOARD"
  fi
fi
exit "$rc"
