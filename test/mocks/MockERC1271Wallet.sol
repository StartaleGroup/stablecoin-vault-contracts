// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC1271} from 'lib/openzeppelin-contracts/contracts/interfaces/IERC1271.sol';
import {ECDSA} from 'lib/openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol';

/// @title MockERC1271Wallet
/// @notice Minimal EIP-1271 smart-contract wallet stand-in, for exercising IdentityRegistry's
///         SignatureChecker-based switchAddress() path against an AA-style signer.
contract MockERC1271Wallet is IERC1271 {
  address public immutable owner;

  constructor(address _owner) {
    owner = _owner;
  }

  function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
    if (ECDSA.recover(hash, signature) == owner) {
      return IERC1271.isValidSignature.selector;
    }
    return 0xffffffff;
  }
}
