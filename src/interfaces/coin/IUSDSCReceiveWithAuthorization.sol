// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

/// @title IUSDSCReceiveWithAuthorization
/// @notice The ERC-3009 function of USDSC that EarnVaultV2.depositWithAuthorization() uses: the
///         bytes-signature overload, which accepts ECDSA and ERC-1271 (smart wallet) signatures.
///         USDSC reverts unless msg.sender == to, so only the payee - here, the vault - can execute
///         an authorization made out to it.
interface IUSDSCReceiveWithAuthorization {
  function receiveWithAuthorization(
    address from,
    address to,
    uint256 value,
    uint256 validAfter,
    uint256 validBefore,
    bytes32 nonce,
    bytes memory signature
  ) external;
}
