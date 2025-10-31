// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// Note: is also IMYieldToOne
// we can use anything IMTokenLike or IMExtension etc

interface IUSDSCMExtension {
  // M0 MYieldToOne: mints fresh USDSC to yieldRecipient and returns amount minted
  function claimYield() external returns (uint256);
}
