#!/usr/bin/env bash
# Run ON THE JUMPBOX before 90-destroy-cluster.sh: /opt/aks-ccc/vanilla/95-destroy-ccc-tests.sh
# Removes the CCC test fixtures of the plain AVM cluster (the Entra app outlives the
# resource group). Keeps ~/ccc-tests-vanilla/results.
exec env CCC_TARGET=vanilla /opt/aks-ccc/95-destroy-ccc-tests.sh "$@"
