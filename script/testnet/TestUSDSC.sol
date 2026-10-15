// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {ERC20Permit} from '@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol';

/// @title TestUSDSC
/// @notice TEST NETWORKS ONLY. A 6-decimal, permit-capable stand-in for USDSC with an open
///         faucet, so backend, keeper and indexer integrations can exercise EarnVaultV2 end to end.
///         Not part of the audited contracts; never deploy as a real asset.
contract TestUSDSC is ERC20, ERC20Permit {
  constructor() ERC20('Test USDSC', 'tUSDSC') ERC20Permit('Test USDSC') {}

  function decimals() public pure override returns (uint8) {
    return 6;
  }

  /// @notice Open faucet: anyone can mint to anyone (test networks only)
  function mint(address to, uint256 amount) external {
    _mint(to, amount);
  }
}
