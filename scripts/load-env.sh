#!/bin/bash
# Helper script to load .env variables (RPC URLs, addresses, explorer keys) for forge scripts.
# Never put private keys in .env: Foundry loads it into every forge test run. Use --account/--ledger.
set -a
source .env
set +a
