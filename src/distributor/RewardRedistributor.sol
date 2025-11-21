// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IRewardRedistributorEventsAndErrors} from '../interfaces/distributor/IRewardRedistributorEventsAndErrors.sol';
import {IEarnVault} from '../interfaces/vaults/earn/IEarnVault.sol';
import {AccessControl} from 'lib/openzeppelin-contracts/contracts/access/AccessControl.sol';
import {IAccessControl} from 'lib/openzeppelin-contracts/contracts/access/IAccessControl.sol';
import {
  AccessControlEnumerable
} from 'lib/openzeppelin-contracts/contracts/access/extensions/AccessControlEnumerable.sol';
import {IERC4626} from 'lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol';
import {IERC20} from 'lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from 'lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol';
import {Pausable} from 'lib/openzeppelin-contracts/contracts/utils/Pausable.sol';
import {ReentrancyGuardTransient} from 'lib/openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol';
import {IMYieldToOne} from 'm-extensions/projects/yieldToOne/IMYieldToOne.sol';

/// @title RewardRedistributor
/// @notice Pulls freshly-minted USDSC yield from the M0 extension, applies an optional fee to Startale,
///         then allocates the **net** yield to eligible cohorts by their share of the
///         **base supply** S (supply before this mint):
///         - EarnVault (checkbox OFF) receives `toEarn = Y_net * T_earn / S_base`
///         - sUSDSC (ERC-4626) vault (checkbox ON) receives `toOn = Y_net * T_yield / S_base`
///         - Remainder (wallets/LP/points + rounding) → Startale (`toStartaleExtra`)
/// @dev    Uses per-cohort integer carry to remove long-run rounding bias.
///         Delivers to EarnVault with transfer→onYield ordering to satisfy its funding invariant.
///         Delivers to sUSDSC via raw transfer, which raises PPS in ERC-4626.
///
///         Architecture:
///         - USDSC_ADDRESS: Single USDSC token address that implements both IERC20 and IMYieldToOne interfaces
///         - Cast to IERC20 for transfers and supply queries (totalSupply, safeTransfer)
///         - Cast to IMYieldToOne for yield operations (claimYield, yield)
contract RewardRedistributor is
  IRewardRedistributorEventsAndErrors,
  AccessControlEnumerable,
  Pausable,
  ReentrancyGuardTransient
{
  using SafeERC20 for IERC20;

  /// Keeper allowed to call distribute()
  bytes32 public constant OPERATOR_ROLE = keccak256('OPERATOR_ROLE');

  /// @notice Maximum fee allowed (basis points).
  uint16 public constant MAX_FEE_BPS = 100; // 100 bps max (1%)

  /// @notice Basis points denominator (10000 = 100%).
  /// @dev    Basis Points (bps) are a unit of measurement for percentages:
  ///         - 1 bps = 0.01% = 1/10,000
  ///         - 10 bps = 0.1% = 10/10,000
  ///         - 10,000 bps = 100% = 10,000/10,000
  ///
  ///         Fee calculation formula:
  ///         `feeAmount = (amount × fee_bps) / BPS_DENOMINATOR`
  ///
  ///         Example: For 30 bps (0.3%) fee on 1,000,000 tokens:
  ///         `feeAmount = (1,000,000 × 30) / 10,000 = 3,000 tokens`
  ///         Verification: 3,000 / 1,000,000 = 0.003 = 0.3% ✓
  uint256 public constant BPS_DENOMINATOR = 10_000;

  /// @notice USDSC token address - used for both transfers/supply queries (IERC20) and yield operations (IMYieldToOne).
  /// @dev    The same address implements both IERC20 and IMYieldToOne interfaces.
  address public immutable USDSC_ADDRESS;

  /// @notice Treasury recipient for fees and ineligible cohort yield.
  address public treasury;

  /// @notice Earn vault (checkbox OFF) that indexes yield via {IEarnVault.onYield}.
  IEarnVault public earnVault;

  /// @notice sUSDSC (ERC-4626) vault that receives yield via raw transfers (no minting).
  IERC4626 public susdscVault;

  /// @notice Fee on newly minted yield expressed in basis points.
  /// @dev    See {BPS_DENOMINATOR} for basis points explanation.
  ///         Examples: 30 bps = 0.3%, 100 bps = 1%, 1000 bps = 10%.
  ///         Initial value: 30 bps (0.3%).
  uint16 public fee_on_yield_bps = 30;

  /// @dev Carry accumulator for EarnVault share calculations across epochs.
  uint256 private carryEarn;

  /// @dev Carry accumulator for sUSDSC share calculations across epochs.
  uint256 private carryOn;

  /// @dev Latest sUSDSC TVL snapshot.
  uint256 public lastSusdscTVL;

  /// @dev Latest snapshot block number.
  uint256 public lastSnapshotBlockNumber;

  /// @dev Latest snapshot timestamp.
  uint256 public lastSnapshotTimestamp;

  /// @dev Maximum age for snapshot validity (e.g., 4 hours).
  uint256 public snapshotMaxAge = 4 hours;

  /// @notice Initializes the redistributor.
  /// @param usdscAddress    USDSC token address (implements both IERC20 and IMYieldToOne interfaces).
  /// @param treasuryAddr   Treasury recipient.
  /// @param earnV          EarnVault (checkbox OFF) recipient.
  /// @param sVault         sUSDSC ERC-4626 vault (checkbox ON) recipient.
  /// @param admin          Admin address; receives DEFAULT_ADMIN_ROLE.
  /// @param keeper         Keeper address; receives OPERATOR_ROLE (can call distribute()).
  constructor(
    address usdscAddress,
    address treasuryAddr,
    IEarnVault earnV,
    IERC4626 sVault,
    address admin,
    address keeper
  ) {
    _validateUsdscContract(usdscAddress);

    if (treasuryAddr == address(0)) revert IRewardRedistributorEventsAndErrors.ZeroAddress('treasury');
    if (address(earnV) == address(0)) revert IRewardRedistributorEventsAndErrors.ZeroAddress('earnVault');
    if (address(sVault) == address(0)) revert IRewardRedistributorEventsAndErrors.ZeroAddress('susdscVault');
    if (admin == address(0)) revert IRewardRedistributorEventsAndErrors.ZeroAddress('admin');
    if (keeper == address(0)) revert IRewardRedistributorEventsAndErrors.ZeroAddress('keeper');

    USDSC_ADDRESS = usdscAddress;
    treasury = treasuryAddr;
    earnVault = earnV;
    susdscVault = sVault;

    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(OPERATOR_ROLE, keeper);
  }

  function _validateUsdscContract(address usdscAddress) internal view {
    if (usdscAddress == address(0)) {
      revert IRewardRedistributorEventsAndErrors.ZeroAddress('USDSC_ADDRESS');
    }

    // Check that the address is a contract
    if (usdscAddress.code.length == 0) revert InvalidUSDSC('NOT_CONTRACT');

    // Validate that the contract implements IERC20
    try IERC20(usdscAddress).totalSupply() returns (uint256) {}
    catch {
      revert IRewardRedistributorEventsAndErrors.InvalidUSDSC('IERC20');
    }

    // Validate that the contract implements IMYieldToOne
    try IMYieldToOne(usdscAddress).yield() returns (uint256) {}
    catch {
      revert IRewardRedistributorEventsAndErrors.InvalidUSDSC('IMYieldToOne');
    }
  }

  /// @notice Updates Treasury address.
  /// @dev    Callable by DEFAULT_ADMIN_ROLE.
  /// @param treasuryAddr   New Treasury address.
  function setTreasury(address treasuryAddr) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (treasuryAddr == address(0)) revert IRewardRedistributorEventsAndErrors.ZeroAddress('treasury');
    treasury = treasuryAddr;
    emit IRewardRedistributorEventsAndErrors.TreasuryUpdated(treasuryAddr);
  }

  /// @notice Updates EarnVault address.
  /// @dev    Callable by DEFAULT_ADMIN_ROLE.
  /// @param earnV          New EarnVault (OFF) address.
  function setEarnVault(IEarnVault earnV) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (address(earnV) == address(0)) revert IRewardRedistributorEventsAndErrors.ZeroAddress('earnVault');
    earnVault = earnV;
    emit IRewardRedistributorEventsAndErrors.EarnVaultUpdated(address(earnV));
  }

  /// @notice Updates sUSDSC vault address.
  /// @dev    Callable by DEFAULT_ADMIN_ROLE.
  /// @param sVault         New sUSDSC ERC-4626 vault (ON) address.
  function setSusdscVault(IERC4626 sVault) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (address(sVault) == address(0)) revert IRewardRedistributorEventsAndErrors.ZeroAddress('susdscVault');
    susdscVault = sVault;
    emit IRewardRedistributorEventsAndErrors.SusdscVaultUpdated(address(sVault));
  }

  /// @notice Updates fee on yield.
  /// @dev    Fee is capped by {MAX_FEE_BPS}. Callable by DEFAULT_ADMIN_ROLE.
  /// @param newFeeBps      New fee on yield in bps (≤ MAX_FEE_BPS).
  function setFeeBps(uint16 newFeeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (newFeeBps > MAX_FEE_BPS) revert IRewardRedistributorEventsAndErrors.FeeTooHigh(newFeeBps, MAX_FEE_BPS);
    fee_on_yield_bps = newFeeBps;
    emit IRewardRedistributorEventsAndErrors.FeeUpdated(newFeeBps);
  }

  /// @notice Updates the maximum age for snapshot validity.
  /// @param newSnapshotMaxAge New snapshot maximum age value.
  function setSnapshotMaxAge(uint256 newSnapshotMaxAge) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (newSnapshotMaxAge < 1 minutes) {
      revert IRewardRedistributorEventsAndErrors.InvalidSnapshotMaxAge(newSnapshotMaxAge, 1 minutes);
    }
    if (newSnapshotMaxAge > 7 days) {
      revert IRewardRedistributorEventsAndErrors.InvalidSnapshotMaxAge(newSnapshotMaxAge, 7 days);
    }
    snapshotMaxAge = newSnapshotMaxAge;
    emit IRewardRedistributorEventsAndErrors.SnapshotMaxAgeUpdated(newSnapshotMaxAge);
  }

  /// @notice Capture sUSDSC vault TVL for next distribution
  /// @dev Must be called in block N before distribute() in block N+x (a few blocks apart/ couple of minutes apart)
  /// @custom:security Prevents same-block TVL manipulation attacks
  function snapshotSusdscTVL() external onlyRole(OPERATOR_ROLE) whenNotPaused {
    lastSusdscTVL = susdscVault.totalAssets();
    lastSnapshotTimestamp = block.timestamp;
    lastSnapshotBlockNumber = block.number;
    emit IRewardRedistributorEventsAndErrors.SusdscTVLSnapshotCaptured(
      lastSusdscTVL, lastSnapshotTimestamp, lastSnapshotBlockNumber
    );
  }

  /// @notice Pauses or unpauses the contract.
  /// @dev    Callable by DEFAULT_ADMIN_ROLE.
  /// @param p              True to pause, false to unpause.
  function pause(bool p) external onlyRole(DEFAULT_ADMIN_ROLE) {
    p ? _pause() : _unpause();
  }

  /// @notice Recovers donations made to the contract to the treasury.
  /// @dev Callable by DEFAULT_ADMIN_ROLE.
  /// @notice The invariant holds that before and after distribute the usdsc balance of address(this) is the same.
  /// @notice The inflow during claimYield happens in the distribute() gets distributed whole leaving no balance.
  /// @notice Hence we can safely assumy at any point in time usdscbalance of address(this) is from the intentional/accidental donations.
  /// @custom:security nonReentrant.
  function recoverDonations() external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
    uint256 balance = IERC20(USDSC_ADDRESS).balanceOf(address(this));
    if (balance > 0) {
      IERC20(USDSC_ADDRESS).safeTransfer(treasury, balance);
      emit IRewardRedistributorEventsAndErrors.DonationsRecovered(balance);
    }
  }

  /// @notice Prevents renunciation of the last DEFAULT_ADMIN_ROLE only.
  /// @dev Overrides AccessControl's renounceRole to ensure at least one admin remains.
  ///      Other roles (e.g., OPERATOR_ROLE) can still be renounced freely.
  ///      Admin can renounce their role only if there are other admins remaining.
  /// @param role The role to renounce.
  /// @param callerConfirmation The address of the caller confirming renunciation.
  function renounceRole(
    bytes32 role,
    address callerConfirmation
  ) public virtual override(AccessControl, IAccessControl) {
    if (role == DEFAULT_ADMIN_ROLE) {
      // Only check last admin protection if the caller actually has the role
      if (hasRole(DEFAULT_ADMIN_ROLE, callerConfirmation) && getRoleMemberCount(DEFAULT_ADMIN_ROLE) <= 1) {
        revert IRewardRedistributorEventsAndErrors.CannotRemoveLastAdmin();
      }
    }
    super.renounceRole(role, callerConfirmation);
  }

  /// @notice Prevents revocation of the last DEFAULT_ADMIN_ROLE only.
  /// @dev Overrides AccessControl's revokeRole to ensure at least one admin remains.
  ///      Non-admin roles (e.g., OPERATOR_ROLE) can be revoked freely.
  ///      Multiple admins can be revoked as long as at least one admin remains.
  ///      Only an account with the admin role can revoke roles from others.
  /// @param role The role to revoke.
  /// @param account The account from which to revoke the role.
  function revokeRole(bytes32 role, address account) public virtual override(AccessControl, IAccessControl) {
    if (role == DEFAULT_ADMIN_ROLE) {
      // Only check last admin protection if the account actually has the role
      if (hasRole(DEFAULT_ADMIN_ROLE, account) && getRoleMemberCount(DEFAULT_ADMIN_ROLE) <= 1) {
        revert IRewardRedistributorEventsAndErrors.CannotRemoveLastAdmin();
      }
    }
    super.revokeRole(role, account);
  }

  /// @notice Validates that this contract is still the yield recipient on the extension.
  /// @dev    Reverts if the yield recipient has changed.
  function _validateYieldRecipient() internal view {
    address currentRecipient = IMYieldToOne(USDSC_ADDRESS).yieldRecipient();
    if (currentRecipient != address(this)) {
      revert IRewardRedistributorEventsAndErrors.YieldRecipientChanged(currentRecipient);
    }
  }

  /**
   * @notice Validates that the snapshot is valid.
   * @dev Performs the following checks:
   *      - Ensures a snapshot has been taken (timestamp and block number are non-zero).
   *      - Verifies the snapshot is from a previous block (prevents same-block manipulation).
   *      - Ensures the snapshot is not too old (must be within `snapshotMaxAge`).
   *      Reverts with appropriate errors if any check fails.
   */
  function _validateSnapShotAge() internal view {
    if (lastSnapshotTimestamp == 0) {
      revert IRewardRedistributorEventsAndErrors.LastSnapshotInvalid();
    }

    if (lastSnapshotBlockNumber == 0) {
      revert IRewardRedistributorEventsAndErrors.LastSnapshotInvalid();
    }

    if (block.number - lastSnapshotBlockNumber < 1) {
      revert IRewardRedistributorEventsAndErrors.MustSnapshotInPreviousBlocks(lastSnapshotBlockNumber, block.number);
    }

    // Check maximum age (snapshot must not be too old)
    if (block.timestamp - lastSnapshotTimestamp > snapshotMaxAge) {
      revert IRewardRedistributorEventsAndErrors.SnapshotTooOld(lastSnapshotTimestamp, block.timestamp, snapshotMaxAge);
    }
  }

  /// @notice Claims pending USDSC yield from the extension and distributes it per policy.
  /// @dev    Sequence:
  ///         1) Record `balanceBefore = IERC20(USDSC_ADDRESS).balanceOf(address(this))`.
  ///         2) `minted = IMYieldToOne(USDSC_ADDRESS).claimYield()` mints fresh USDSC to this contract (must be yieldRecipient).
  ///         3) Calculate `gross = balanceBefore + minted` to handle both normal flow and external claimYield() calls.
  ///         4) `feeToStartale = gross * fee_on_yield_bps / 10_000`.
  ///         5) Compute `S_base = IERC20(USDSC_ADDRESS).totalSupply() - minted` (supply **before** this mint).
  ///         6) Read TVLs: `T_earn = earnVault.totalPrincipal()`, `T_yield = lastSusdscTVL` (snapshot TVL).
  ///         7) Allocate net using carries:
  ///            `toEarn = floor((net*T_earn + carryEarn)/S_base)`, `carryEarn = (net*T_earn + carryEarn) % S_base`
  ///            `toOn   = floor((net*T_yield   + carryOn)/S_base)`,   `carryOn   = (net*T_yield   + carryOn)   % S_base`
  ///            `toStartaleExtra = net - (toEarn + toOn)`
  ///         8) Transfers:
  ///            - Startale: `feeToStartale + toStartaleExtra`
  ///            - EarnVault: transfer `toEarn` **then** call `earnVault.onYield(toEarn)`
  ///            - sUSDSC: transfer `toOn` (PPS rises)
  /// @custom:security nonReentrant and Pausable.
  function distribute() external whenNotPaused onlyRole(OPERATOR_ROLE) nonReentrant {
    _validateYieldRecipient();
    _validateSnapShotAge();
    // Note: claimYield() on USDSCextension is not public method anymore and is gated by trusted actors.
    // Hence any other accruals before/after distribute are pure donations and not newly minted.
    uint256 minted = IMYieldToOne(USDSC_ADDRESS).claimYield();

    if (minted == 0) return;

    uint256 feeToStartale;
    uint256 toEarn;
    uint256 toOn;
    uint256 toStartaleExtra;
    uint256 S_base;
    uint256 T_earn;
    uint256 T_yield;

    (feeToStartale, toEarn, toOn, toStartaleExtra, S_base, T_earn, T_yield) = _calculateSplit(minted, true, false);

    if (S_base == 0) {
      if (feeToStartale > 0) IERC20(USDSC_ADDRESS).safeTransfer(treasury, feeToStartale);
      if (toStartaleExtra > 0) IERC20(USDSC_ADDRESS).safeTransfer(treasury, toStartaleExtra);
      emit Distributed(minted, feeToStartale, 0, 0, toStartaleExtra, 0, 0, 0);
      return;
    }

    if (S_base > 0) {
      uint256 net = minted - feeToStartale;
      uint256 numEarn = net * T_earn + carryEarn;
      carryEarn = numEarn % S_base;

      uint256 numOn = net * T_yield + carryOn;
      carryOn = numOn % S_base;
    }

    uint256 startaleTotal = feeToStartale + toStartaleExtra;
    // Note: We may split it into two transfers to two different addresses.
    if (startaleTotal > 0) IERC20(USDSC_ADDRESS).safeTransfer(treasury, startaleTotal);

    if (toEarn > 0) {
      IERC20(USDSC_ADDRESS).safeTransfer(address(earnVault), toEarn);
      earnVault.onYield(toEarn);
    }
    if (toOn > 0) {
      IERC20(USDSC_ADDRESS).safeTransfer(address(susdscVault), toOn);
    }

    emit Distributed(minted, feeToStartale, toEarn, toOn, toStartaleExtra, S_base, T_earn, T_yield);
    // balanceBefore and balanceAfter distribute would be the same.
  }

  /// @notice Preview a split for a hypothetical minted amount.
  /// @dev    Pure math helper (no state/carry usage). Does **not** call the extension.
  /// @param minted  Hypothetical fresh yield to allocate (pre-fee).
  /// @return feeToStartale     Fee portion (bps of `minted`) to Startale.
  /// @return toEarn            Portion of net allocated to EarnVault (OFF) **without carry**.
  /// @return toOn              Portion of net allocated to sUSDSC (ON) **without carry**.
  /// @return toStartaleExtra   Remainder of net: ineligible cohorts + rounding.
  /// @return S_base            Total USDSC supply **before** this mint (= totalSupply - minted if ≥0).
  /// @return T_earn            EarnVault TVL used for allocation (`earnVault.totalPrincipal()`).
  /// @return T_yield              sUSDSCVault TVL used for allocation (`susdscVault.totalAssets()`).
  function previewSplit(uint256 minted)
    external
    view
    returns (
      uint256 feeToStartale,
      uint256 toEarn,
      uint256 toOn,
      uint256 toStartaleExtra,
      uint256 S_base,
      uint256 T_earn,
      uint256 T_yield
    )
  {
    return _calculateSplit(minted, false, true);
  }

  /// @notice Preview a split using the extension's **current pending** yield (no carries).
  /// @dev    Reads {IUSDSCMExtension.yield}. Pure preview; does not mutate.
  /// @return couldBeMinted     Pending fresh yield on the extension at this moment.
  /// @return feeToStartale     Fee portion (bps of `couldBeMinted`) to Startale.
  /// @return toEarn            Portion of net to EarnVault (OFF) **without carry**.
  /// @return toOn              Portion of net to sUSDSC (ON) **without carry**.
  /// @return toStartaleExtra   Remainder of net: ineligible cohorts + rounding.
  /// @return S_base            Total USDSC supply **before** this mint.
  /// @return T_earn            EarnVault TVL used for allocation.
  /// @return T_yield              sUSDSCVault TVL used for allocation.
  function previewSplitCurrent()
    external
    view
    returns (
      uint256 couldBeMinted,
      uint256 feeToStartale,
      uint256 toEarn,
      uint256 toOn,
      uint256 toStartaleExtra,
      uint256 S_base,
      uint256 T_earn,
      uint256 T_yield
    )
  {
    couldBeMinted = IMYieldToOne(USDSC_ADDRESS).yield();
    (feeToStartale, toEarn, toOn, toStartaleExtra, S_base, T_earn, T_yield) =
      _calculateSplit(couldBeMinted, false, true);
  }

  /// @notice Exact dry-run of {distribute} against current chain state (includes carries).
  /// @dev    Reads extension's pending yield and current carries; does not mutate state.
  /// @return couldBeMinted            Pending fresh yield on the extension at this moment.
  /// @return feeToStartale     Fee portion (bps of `couldBeMinted`) to Startale.
  /// @return toEarn            Portion of net to EarnVault (OFF) **with carry** (exact if called now).
  /// @return toOn              Portion of net to sUSDSC (ON) **with carry** (exact if called now).
  /// @return toStartaleExtra   Remainder of net: ineligible cohorts + rounding.
  /// @return S_base            Total USDSC supply **before** this mint.
  /// @return T_earn            EarnVault TVL used for allocation.
  /// @return T_yield              sUSDSCVault TVL used for allocation.
  function previewDistribute()
    external
    view
    returns (
      uint256 couldBeMinted,
      uint256 feeToStartale,
      uint256 toEarn,
      uint256 toOn,
      uint256 toStartaleExtra,
      uint256 S_base,
      uint256 T_earn,
      uint256 T_yield
    )
  {
    couldBeMinted = IMYieldToOne(USDSC_ADDRESS).yield();
    (feeToStartale, toEarn, toOn, toStartaleExtra, S_base, T_earn, T_yield) = _calculateSplit(couldBeMinted, true, true);
  }

  /// @notice Internal helper to calculate yield distribution split.
  /// @dev    Core calculation logic shared by preview functions and distribute().
  /// @param minted            Amount of fresh yield to allocate (pre-fee).
  /// @param useCarries        Whether to include carry calculations (true for distribute/previewDistribute).
  /// @param preMint           Whether this is a preview (true) or actual distribution (false).
  /// @return feeToStartale    Fee portion (bps of `minted`) to Startale.
  /// @return toEarn           Portion of net allocated to EarnVault (OFF).
  /// @return toOn             Portion of net allocated to sUSDSC (ON).
  /// @return toStartaleExtra  Remainder of net: ineligible cohorts + rounding.
  /// @return S_base           Total USDSC supply **before** this mint.
  /// @return T_earn           EarnVault TVL used for allocation.
  /// @return T_yield          sUSDSCVault TVL used for allocation.
  function _calculateSplit(
    uint256 minted,
    bool useCarries,
    bool preMint
  )
    internal
    view
    returns (
      uint256 feeToStartale,
      uint256 toEarn,
      uint256 toOn,
      uint256 toStartaleExtra,
      uint256 S_base,
      uint256 T_earn,
      uint256 T_yield
    )
  {
    if (minted == 0) {
      return (0, 0, 0, 0, _supplyBase(0), earnVault.totalPrincipal(), lastSusdscTVL);
    }

    feeToStartale = (minted * fee_on_yield_bps) / BPS_DENOMINATOR;
    uint256 net = minted - feeToStartale;

    // Use _supplyBase() helper to calculate S_base
    // For preview (preMint=true): use current supply (minted=0)
    // For actual distribution (preMint=false): use supply before mint (minted=minted)
    S_base = _supplyBase(preMint ? 0 : minted);

    T_earn = earnVault.totalPrincipal();
    T_yield = lastSusdscTVL; // Use snapshot TVL to prevent manipulation

    if (S_base == 0) {
      toStartaleExtra = net;
      return (feeToStartale, 0, 0, toStartaleExtra, S_base, T_earn, T_yield);
    }

    if (useCarries) {
      uint256 _carryEarn = carryEarn;
      uint256 _carryOn = carryOn;

      uint256 numEarn = net * T_earn + _carryEarn;
      toEarn = numEarn / S_base;

      uint256 numOn = net * T_yield + _carryOn;
      toOn = numOn / S_base;
    } else {
      toEarn = (net * T_earn) / S_base;
      toOn = (net * T_yield) / S_base;
    }

    toStartaleExtra = net - (toEarn + toOn);
  }

  /// @notice Computes the **base supply** used for allocation for a hypothetical `minted` amount.
  /// @dev    Defined as `totalSupply() > minted ? totalSupply() - minted : 0`.
  /// @param minted  Hypothetical fresh yield.
  /// @return        Total USDSC supply **before** the hypothetical mint.
  function _supplyBase(uint256 minted) internal view returns (uint256) {
    uint256 SNow = IERC20(USDSC_ADDRESS).totalSupply();
    return SNow > minted ? SNow - minted : 0;
  }
}
