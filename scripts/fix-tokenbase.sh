#!/bin/bash

# Fix TokenBase.sol circular import issue
# This script patches the problematic import in TokenBase.sol files

echo "🔧 Applying TokenBase.sol circular import fix..."

# Detect OS for sed compatibility
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    SED_CMD="sed -i ''"
else
    # Linux (GitHub CI)
    SED_CMD="sed -i"
fi

# Fix the main TokenBase.sol file
TOKENBASE_FILE1="lib/native-token-transfers/evm/lib/wormhole-solidity-sdk/src/TokenBase.sol"
if [ -f "$TOKENBASE_FILE1" ]; then
    echo "  Fixing $TOKENBASE_FILE1"
    $SED_CMD 's/import {Base} from "\.\/WormholeRelayerSDK\.sol";/import {Base} from ".\/Base.sol";/g' "$TOKENBASE_FILE1"
fi

# Fix the m-portal TokenBase.sol file  
TOKENBASE_FILE2="lib/m-portal/lib/native-token-transfers/evm/lib/wormhole-solidity-sdk/src/TokenBase.sol"
if [ -f "$TOKENBASE_FILE2" ]; then
    echo "  Fixing $TOKENBASE_FILE2"
    $SED_CMD 's/import {Base} from "\.\/WormholeRelayerSDK\.sol";/import {Base} from ".\/Base.sol";/g' "$TOKENBASE_FILE2"
fi

echo "✅ TokenBase.sol circular import fix applied successfully!"
