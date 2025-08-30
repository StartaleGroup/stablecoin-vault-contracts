// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IEarnVault {
  // TVL for pro-rata split
  function totalPrincipal() external view returns (uint256);
  // asset this vault uses (USDx)
  function asset() external view returns (address);

  // TODO // Review
  // user flows (checkbox OFF)
  function depositClaim(uint256 amount) external;
  function claimInterest(uint256 amount) external;
  function withdrawClaim(uint256 amountPrincipal) external;

  // redistributor hook (must be called AFTER tokens are transferred in)
  function onYield(uint256 amount) external;
}
