#!/usr/bin/env bash
# Run ON THE JUMPBOX after 40-setup-ccc-tests.sh: /opt/aks-ccc/vanilla/50-run-ccc-tests.sh
# (or from your laptop with workshop/aks-vanilla/scripts/55-run-ccc-tests-from-laptop.sh).
# Results: ~/ccc-tests-vanilla/results/<UTC time>/
exec env CCC_TARGET=vanilla /opt/aks-ccc/50-run-ccc-tests.sh "$@"
