// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Note: is also IMYieldToOne
// we can use anything IMTokenLike or IMExtension etc

interface IUSDxMExtension {
    // M0 MYieldToOne: mints fresh USDx to yieldRecipient and returns amount minted
    function claimYield() external returns (uint256);
}
