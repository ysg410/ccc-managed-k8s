#!/usr/bin/env bash
# Run on your laptop after /opt/aks-ccc/vanilla/40-setup-ccc-tests.sh ran on the jumpbox:
#   workshop/aks-vanilla/scripts/55-run-ccc-tests-from-laptop.sh
# The workshop's laptop runner (untrusted-network reachability probe) pointed at the
# plain AVM cluster. Results: workshop/aks-vanilla/ccc-results/<UTC time>/ (gitignored).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec env CCC_TARGET=vanilla CCC_RESULTS_DIR="$ROOT/ccc-results" "$ROOT/../aks/scripts/55-run-ccc-tests-from-laptop.sh" "$@"
