// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Ownable} from 'lib/openzeppelin-contracts/contracts/access/Ownable.sol';
import {Ownable2Step} from 'lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol';
import {IERC20} from 'lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from 'lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol';

/// @dev The one EarnVault entry point this contract uses
interface IEarnVaultBoostReward {
  function onBoostReward(address token, uint256 amount) external;
  function asset() external view returns (address);
}

/**
 * @title BoostRewardFunder
 * @notice Set as the EarnVault's `boostRewardKeeper` so an automated operator can run the boost
 *         reward programme without being able to index unfunded rewards.
 * @dev EarnVault.onBoostReward() expects its caller to have transferred `amount` in beforehand, as a
 *      separate step. This contract makes funding and indexing one step: `fund()` moves exactly
 *      `amount` from the operator to the vault and indexes exactly that amount, in one transaction, so
 *      the two can never get out of sync. The operator can only distribute its own tokens, capped per
 *      call and per day, and the token is fixed at deployment to the vault's own asset (USDSC). The daily
 *      cap resets at each UTC day boundary, so up to 2 x maxPerDay can land around midnight.
 * @dev Holds no funds: tokens go straight from the operator to the vault. The owner (the Safe) sets
 *      the operator and the caps. To stop the programme, the owner sets the vault's
 *      boostRewardKeeper elsewhere, or sets the caps to zero here.
 */
contract BoostRewardFunder is Ownable2Step {
  using SafeERC20 for IERC20;

  IEarnVaultBoostReward public immutable vault;
  IERC20 public immutable token;

  address public operator;
  uint256 public maxPerCall;
  uint256 public maxPerDay;

  /// @notice UTC day number (block.timestamp / 1 days) that `fundedToday` refers to
  uint256 public currentDay;
  uint256 public fundedToday;

  event OperatorChanged(address indexed oldOperator, address indexed newOperator);
  event LimitsChanged(uint256 maxPerCall, uint256 maxPerDay);
  event BoostFunded(address indexed operator, uint256 amount, uint256 indexed day, uint256 fundedToday);

  error ZeroAddress();
  error ZeroAmount();
  error NotOperator();
  error AboveMaxPerCall(uint256 amount, uint256 maxPerCall);
  error AboveDailyLimit(uint256 fundedToday, uint256 amount, uint256 maxPerDay);
  error TokenIsNotVaultAsset();
  error MaxPerCallAboveMaxPerDay();
  error RenounceOwnershipDisabled();

  constructor(
    address vault_,
    address token_,
    address owner_,
    address operator_,
    uint256 maxPerCall_,
    uint256 maxPerDay_
  ) Ownable(owner_) {
    if (vault_ == address(0) || token_ == address(0) || operator_ == address(0)) {
      revert ZeroAddress();
    }
    if (IEarnVaultBoostReward(vault_).asset() != token_) revert TokenIsNotVaultAsset();
    if (maxPerCall_ > maxPerDay_) revert MaxPerCallAboveMaxPerDay();
    vault = IEarnVaultBoostReward(vault_);
    token = IERC20(token_);
    operator = operator_;
    maxPerCall = maxPerCall_;
    maxPerDay = maxPerDay_;
    emit OperatorChanged(address(0), operator_);
    emit LimitsChanged(maxPerCall_, maxPerDay_);
  }

  /// @notice Pull `amount` from the operator into the vault and index it as a boost reward
  /// @dev The operator must have approved this contract for `amount` of `token`. The vault must be
  ///      unpaused. If the vault has no depositors, the vault sends the funded tokens to its treasury
  ///      (existing vault behaviour) and nothing is indexed. This only works once the vault's owner
  ///      has set this contract as the vault's `boostRewardKeeper`.
  function fund(uint256 amount) external {
    if (msg.sender != operator) revert NotOperator();
    if (amount == 0) revert ZeroAmount();
    if (amount > maxPerCall) revert AboveMaxPerCall(amount, maxPerCall);

    uint256 day = block.timestamp / 1 days;
    if (day != currentDay) {
      currentDay = day;
      fundedToday = 0;
    }
    uint256 total = fundedToday + amount;
    if (total > maxPerDay) revert AboveDailyLimit(fundedToday, amount, maxPerDay);
    fundedToday = total;

    token.safeTransferFrom(msg.sender, address(vault), amount);
    vault.onBoostReward(address(token), amount);
    emit BoostFunded(msg.sender, amount, day, total);
  }

  function setOperator(address newOperator) external onlyOwner {
    if (newOperator == address(0)) revert ZeroAddress();
    emit OperatorChanged(operator, newOperator);
    operator = newOperator;
  }

  /// @dev Setting either cap to 0 pauses the programme
  function setLimits(uint256 newMaxPerCall, uint256 newMaxPerDay) external onlyOwner {
    if (newMaxPerCall > newMaxPerDay) revert MaxPerCallAboveMaxPerDay();
    maxPerCall = newMaxPerCall;
    maxPerDay = newMaxPerDay;
    emit LimitsChanged(newMaxPerCall, newMaxPerDay);
  }

  /// @dev Disabled so ownership cannot be dropped by mistake
  function renounceOwnership() public view override {
    revert RenounceOwnershipDisabled();
  }
}
