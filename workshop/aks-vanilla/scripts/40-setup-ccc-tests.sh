#!/usr/bin/env bash
# Run ON THE JUMPBOX after 10-build-cluster.sh: /opt/aks-ccc/vanilla/40-setup-ccc-tests.sh
# The workshop's CCC test setup, pointed at the plain AVM cluster (~/ccc-tests-vanilla).
exec env CCC_TARGET=vanilla /opt/aks-ccc/40-setup-ccc-tests.sh "$@"
