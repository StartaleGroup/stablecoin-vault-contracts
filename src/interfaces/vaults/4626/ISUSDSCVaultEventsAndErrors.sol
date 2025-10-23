// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface ISUSDSCVaultEventsAndErrors {
  error AdminCannotBeZeroAddress();
  error PauserCannotBeZeroAddress();
  error TokenCannotBeZeroAddress();
  error ToCannotBeZeroAddress();
  error AmountCannotBeZero();
  error TokenCannotBeUSDSC();
}
