// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface ISUSDSCVaultEventsAndErrors {
  error AdminCannotBeZeroAddress();
  error PauserCannotBeZeroAddress();
  error TokenCannotBeZeroAddress();
  error ToCannotBeZeroAddress();
  error AmountCannotBeZero();
  error TokenCannotBeUSDSC();
}
