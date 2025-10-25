#!/bin/bash

# Generate filtered coverage report for src/vaults and src/distributor only
# This script is a wrapper around 'make coverage-filtered' for convenience
# 
# Usage: 
#   ./scripts/coverage-filtered.sh [profile]
#   make coverage-filtered profile=<profile>
#
# Examples:
#   ./scripts/coverage-filtered.sh
#   ./scripts/coverage-filtered.sh ci
#   make coverage-filtered
#   make coverage-filtered profile=ci

set -e

PROFILE=${1:-default}

# Simply call the Makefile target
make coverage-filtered profile=$PROFILE

