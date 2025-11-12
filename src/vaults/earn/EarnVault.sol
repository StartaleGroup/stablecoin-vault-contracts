// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IEarnVault} from '../../interfaces/vaults/earn/IEarnVault.sol';
import {IEarnVaultEventsAndErrors} from '../../interfaces/vaults/earn/IEarnVaultEventsAndErrors.sol';
import {BoostRewardsLib} from './BoostRewardsLib.sol';
import {Ownable} from 'lib/openzeppelin-contracts/contracts/access/Ownable.sol';
import {Ownable2Step} from 'lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol';
import {IERC20} from 'lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol';
import {IERC20Permit} from 'lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Permit.sol';
import {SafeERC20} from 'lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol';
import {Pausable} from 'lib/openzeppelin-contracts/contracts/utils/Pausable.sol';
import {ReentrancyGuardTransient} from 'lib/openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol';
import {Math} from 'lib/openzeppelin-contracts/contracts/utils/math/Math.sol';

/// @title EarnVault (claimable yield)
/// @notice Users deposit USDSC, accrue claimable USDSC via index accounting, and can claim/withdraw anytime.
///         A distributor pushes yield: transfer USDSC to this contract, then call onYield(amount).
/// Accounting:
///   - globalIndex is in RAY (1e27) for precision.
///   - User state: principal, userIndex, accrued.
///   - When yield arrives and totalPrincipal>0: globalIndex += amount*RAY/totalPrincipal.
///   - If totalPrincipal==0 at yield time: amount is transferred directly to treasury.
/// Invariant (funding): USDSC balance >= claimReserve.
contract EarnVault is IEarnVault, IEarnVaultEventsAndErrors, Ownable2Step, Pausable, ReentrancyGuardTransient {
  using SafeERC20 for IERC20;

  // ================================================================
  // CONSTANTS / IMMUTABLES
  // ================================================================

  /// @dev High precision for yield calculations (MakerDAO standard)
  uint256 public constant RAY = 1e27;

  /// @dev USDSC token interface
  IERC20 public immutable USDSC;

  // ================================================================
  // STORAGE
  // ================================================================

  /// @dev Address authorized to call onYield() (RewardRedistributor contract)
  address public yieldRedistributor;

  /// @dev Address authorized to call onBoostReward() (keeper/operator address)
  address public boostRewardKeeper;

  /// @dev Address authorized to pause/unpause the contract
  address public pauser;

  /// @dev Receives yield when no deposits exist, surplus sweeps
  address public treasury;

  /// @dev Sum of user principals
  uint256 public totalPrincipal;

  /// @dev Global index (scaled 1e27 - RAY precision)
  uint256 public globalIndex = RAY;

  /// @dev Assets available to pay claims/withdraws
  uint256 public claimReserve;

  /// @dev Remainder in "RAY * principal" space for exact precision
  uint256 private _carryRay;

  /// @dev User principal amounts
  mapping(address => uint256) public principal;

  /// @dev User's last updated index
  mapping(address => uint256) public userIndex;

  /// @dev User's accrued interest
  mapping(address => uint256) public accrued;

  /// @dev Optional blacklist
  mapping(address => bool) public isBlacklisted;

  /// @dev Token => global boost index
  mapping(address => uint256) public boostGlobalIndex;

  /// @dev Token => claimable boost reserves
  mapping(address => uint256) public boostClaimReserve;

  /// @dev User => token => last boost index
  mapping(address => mapping(address => uint256)) public userBoostIndex;

  /// @dev User => token => accrued boost rewards
  mapping(address => mapping(address => uint256)) public userBoostAccrued;

  /// @dev List of tokens that have been distributed
  address[] public activeBoostTokens;

  /// @dev Token => index in activeBoostTokens array
  mapping(address => uint256) public boostTokenIndex;

  // ================================================================
  // MODIFIERS
  // ================================================================

  /// @dev Modifier to check if caller is the yield redistributor
  modifier onlyYieldRedistributor() {
    _onlyYieldRedistributor();
    _;
  }

  /// @dev Modifier to check if caller is the boost reward keeper
  modifier onlyBoostRewardKeeper() {
    _onlyBoostRewardKeeper();
    _;
  }

  /// @dev Modifier to check if caller is the pauser
  modifier onlyPauser() {
    _onlyPauser();
    _;
  }

  // ================================================================
  // CONSTRUCTOR
  // ================================================================

  constructor(
    address usdsc,
    address owner,
    address yieldRedistributorAddr,
    address treasuryAddr,
    address pauserAddr,
    address boostRewardKeeperAddr
  ) Ownable(owner) {
    if (usdsc == address(0) || owner == address(0)) {
      revert IEarnVaultEventsAndErrors.CanNotBeZeroAddress();
    }
    if (yieldRedistributorAddr == address(0) || treasuryAddr == address(0)) {
      revert IEarnVaultEventsAndErrors.CanNotBeZeroAddress();
    }
    if (pauserAddr == address(0)) revert IEarnVaultEventsAndErrors.CanNotBeZeroAddress();
    if (boostRewardKeeperAddr == address(0)) revert IEarnVaultEventsAndErrors.CanNotBeZeroAddress();

    USDSC = IERC20(usdsc);
    treasury = treasuryAddr;
    yieldRedistributor = yieldRedistributorAddr;
    boostRewardKeeper = boostRewardKeeperAddr;
    pauser = pauserAddr;
  }

  // ================================================================
  // RECEIVE / FALLBACK
  // ================================================================

  /// @dev Reject ETH transfers to prevent accidental loss
  receive() external payable {
    revert IEarnVaultEventsAndErrors.EthNotAccepted();
  }

  /// @dev Reject ETH transfers to prevent accidental loss
  fallback() external payable {
    revert IEarnVaultEventsAndErrors.EthNotAccepted();
  }

  // ================================================================
  // EXTERNAL FUNCTIONS (STATE-CHANGING)
  // ================================================================

  /// @notice Set the yield redistributor address
  /// @param who New yield redistributor address
  function setYieldRedistributor(address who) external onlyOwner {
    if (who == address(0)) revert IEarnVaultEventsAndErrors.CanNotBeZeroAddress();
    address oldRedistributor = yieldRedistributor;
    yieldRedistributor = who;
    emit YieldRedistributorChanged(msg.sender, oldRedistributor, who);
  }

  /// @notice Set the boost reward keeper address
  /// @param who New boost reward keeper address
  function setBoostRewardKeeper(address who) external onlyOwner {
    if (who == address(0)) revert IEarnVaultEventsAndErrors.CanNotBeZeroAddress();
    address oldKeeper = boostRewardKeeper;
    boostRewardKeeper = who;
    emit IEarnVaultEventsAndErrors.BoostRewardKeeperChanged(msg.sender, oldKeeper, who);
  }

  /// @notice Set the treasury address
  /// @param who New treasury address
  function setTreasury(address who) external onlyOwner {
    if (who == address(0)) revert IEarnVaultEventsAndErrors.CanNotBeZeroAddress();
    address oldTreasury = treasury;
    treasury = who;
    emit TreasuryChanged(msg.sender, oldTreasury, who);
  }

  /// @notice Set the pauser address
  /// @param who New pauser address
  function setPauser(address who) external onlyOwner {
    if (who == address(0)) revert IEarnVaultEventsAndErrors.CanNotBeZeroAddress();

    address oldPauser = pauser;
    pauser = who;

    emit PauserChanged(msg.sender, oldPauser, who);
  }

  /// @notice Set blacklist status for an address
  /// @param who Address to update blacklist status for
  /// @param blacklisted Whether address should be blacklisted
  function setBlacklisted(address who, bool blacklisted) external onlyOwner {
    bool oldStatus = isBlacklisted[who];
    isBlacklisted[who] = blacklisted;
    emit BlacklistStatusChanged(msg.sender, who, oldStatus, blacklisted);
  }

  /// @notice Pause the contract (emergency stop)
  /// @dev Can be called by designated pauser only
  function pause() external onlyPauser {
    _pause();
  }

  /// @notice Unpause the contract
  /// @dev Can be called by designated pauser only
  function unpause() external onlyPauser {
    _unpause();
  }

  /// @notice Prevents renunciation of ownership.
  /// @dev Overrides Ownable2Step's renounceOwnership to protect against accidental loss of ownership.
  ///      Owner can still transfer ownership using the 2-step process (transferOwnership + acceptOwnership).
  function renounceOwnership() public view override onlyOwner {
    revert IEarnVaultEventsAndErrors.OwnershipRenunciationDisabled();
  }

  /// @notice Deposit USDSC tokens to earn yield
  /// @dev Reserves principal 1:1 in claimReserve to ensure withdrawals are always possible
  /// @param amount Amount of USDSC tokens to deposit
  function deposit(uint256 amount) external whenNotPaused nonReentrant {
    _checkNotBlacklisted(msg.sender);
    if (amount == 0) revert IEarnVaultEventsAndErrors.ZeroAmount();

    _settle(msg.sender);

    // Settle boost rewards for all active tokens BEFORE updating principal
    for (uint256 i = 0; i < activeBoostTokens.length; i++) {
      _settleBoost(msg.sender, activeBoostTokens[i]);
    }

    USDSC.safeTransferFrom(msg.sender, address(this), amount);
    principal[msg.sender] += amount;
    totalPrincipal += amount;
    claimReserve += amount; // reserve principal 1:1

    emit Deposit(msg.sender, amount);
  }

  /// @notice Deposit USDSC tokens using permit (gasless approval)
  /// @dev Same as deposit() but uses permit for approval in same transaction
  /// @dev Safely handles tokens that may not implement IERC20Permit
  /// @param amount Amount of USDSC tokens to deposit
  /// @param deadline Permit deadline timestamp
  /// @param v Permit signature parameter v
  /// @param r Permit signature parameter r
  /// @param s Permit signature parameter s
  function depositWithPermit(
    uint256 amount,
    uint256 deadline,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) external whenNotPaused nonReentrant {
    _checkNotBlacklisted(msg.sender);
    if (amount == 0) revert IEarnVaultEventsAndErrors.ZeroAmount();

    // Safely attempt permit - revert with clear error if not supported
    try IERC20Permit(address(USDSC)).permit(msg.sender, address(this), amount, deadline, v, r, s) {
    // Permit succeeded, continue with deposit
    }
    catch {
      revert IEarnVaultEventsAndErrors.PermitFailed();
    }
    _settle(msg.sender);

    // Settle boost rewards for all active tokens BEFORE updating principal
    for (uint256 i = 0; i < activeBoostTokens.length; i++) {
      _settleBoost(msg.sender, activeBoostTokens[i]);
    }

    USDSC.safeTransferFrom(msg.sender, address(this), amount);
    principal[msg.sender] += amount;
    totalPrincipal += amount;
    claimReserve += amount; // reserve principal 1:1

    emit Deposit(msg.sender, amount);
  }

  /// @notice Withdraw any amount up to principal amount
  /// @param amount Amount of principal to withdraw (max: user's principal)
  /// @dev Automatically claims ALL accrued interest (USDSC + boost rewards) when withdrawing
  /// @dev User can only withdraw their principal, but gets all rewards automatically
  function withdraw(uint256 amount) external whenNotPaused nonReentrant {
    _checkNotBlacklisted(msg.sender);
    if (amount == 0) revert IEarnVaultEventsAndErrors.ZeroAmount();

    _settle(msg.sender);

    uint256 p = principal[msg.sender];
    if (amount > p) revert IEarnVaultEventsAndErrors.InsufficientPrincipal();

    // Settle and claim ALL boost rewards in single loop
    for (uint256 i = 0; i < activeBoostTokens.length; i++) {
      address token = activeBoostTokens[i];
      _settleBoost(msg.sender, token);
      BoostRewardsLib.claimBoostReward(
        msg.sender,
        token,
        p, // Use original principal before withdrawal
        userBoostIndex[msg.sender][token],
        boostGlobalIndex[token],
        userBoostAccrued,
        boostClaimReserve
      );
    }

    // Update state AFTER settling all rewards
    principal[msg.sender] = p - amount;
    totalPrincipal -= amount;
    claimReserve -= amount; // Reduce claim reserve by withdrawn principal

    // Transfer principal
    USDSC.safeTransfer(msg.sender, amount);

    // Automatically claim ALL USDSC yield
    uint256 usdscYield = accrued[msg.sender];
    if (usdscYield > 0) {
      if (claimReserve < usdscYield) revert IEarnVaultEventsAndErrors.InsufficientFunding();
      accrued[msg.sender] = 0;
      claimReserve -= usdscYield;
      USDSC.safeTransfer(msg.sender, usdscYield);
      emit InterestClaimed(msg.sender, usdscYield);
    }

    // Emit events
    emit Withdraw(msg.sender, amount);
  }

  /// @notice Claim all accrued interest to caller's address
  /// @dev Settles user's position and transfers all accrued yield (USDSC + boost rewards)
  function claim() external whenNotPaused nonReentrant {
    _checkNotBlacklisted(msg.sender);
    _settle(msg.sender);

    uint256 usdscAmt = accrued[msg.sender];
    bool hasUSDSCClaim = usdscAmt > 0;
    bool hasBoostClaim = false;

    // Claim USDSC interest
    if (hasUSDSCClaim) {
      if (claimReserve < usdscAmt) revert IEarnVaultEventsAndErrors.InsufficientFunding();
      accrued[msg.sender] = 0;
      claimReserve -= usdscAmt;
      USDSC.safeTransfer(msg.sender, usdscAmt);
      emit InterestClaimed(msg.sender, usdscAmt);
    }

    // Settle and claim all boost rewards in single loop
    for (uint256 i = 0; i < activeBoostTokens.length; i++) {
      address token = activeBoostTokens[i];
      _settleBoost(msg.sender, token);
      uint256 claimedAmount = BoostRewardsLib.claimBoostReward(
        msg.sender,
        token,
        principal[msg.sender],
        userBoostIndex[msg.sender][token],
        boostGlobalIndex[token],
        userBoostAccrued,
        boostClaimReserve
      );
      if (claimedAmount > 0) {
        hasBoostClaim = true;
      }
    }

    if (!hasUSDSCClaim && !hasBoostClaim) revert IEarnVaultEventsAndErrors.NothingToClaim();
  }

  /// @notice Distribute yield to vault users (callable only by yield redistributor)
  /// @dev MUST be called AFTER transferring `amount` USDSC to this contract
  /// @dev Enforces funding invariant: USDSC.balance >= claimReserve + amount
  /// @param amount Amount of USDSC yield to distribute
  function onYield(uint256 amount) external onlyYieldRedistributor nonReentrant {
    if (amount == 0) return;

    // Verify actual balance before updating accounting
    uint256 bal = USDSC.balanceOf(address(this));

    if (totalPrincipal == 0) {
      // No deposits: just need enough for treasury transfer
      if (bal < amount) revert IEarnVaultEventsAndErrors.InsufficientFunding();
      USDSC.safeTransfer(treasury, amount);
      emit YieldTransferredToTreasury(amount);
      return;
    }

    // Deposits exist: need enough for claimReserve + new yield
    if (bal < claimReserve + amount) revert IEarnVaultEventsAndErrors.InsufficientFunding();

    // Exact, immediate index update with Ray remainder carry
    // delta = floor( (amount*RAY + _carryRay) / totalPrincipal )
    // _carryRay = (amount*RAY + _carryRay) % totalPrincipal
    unchecked {
      uint256 num = amount * RAY + _carryRay;
      uint256 delta = num / totalPrincipal;
      _carryRay = num % totalPrincipal;
      globalIndex += delta;
    }

    claimReserve += amount;
    emit YieldIndexed(amount, globalIndex, claimReserve);
  }

  /// @notice Distribute boost rewards (ASTR, DOT, etc.) to vault users
  /// @dev MUST be called AFTER transferring `amount` of `token` to this contract
  /// @dev Uses same logic as USDSC yield - distributed proportionally based on principal
  /// @dev Can be called by boost reward keeper (keeper/operator address)
  /// @param token Token address to distribute as boost rewards
  /// @param amount Amount of boost tokens to distribute
  function onBoostReward(address token, uint256 amount) external onlyBoostRewardKeeper whenNotPaused nonReentrant {
    BoostRewardsLib.distributeBoostReward(
      token, amount, totalPrincipal, treasury, boostGlobalIndex, boostClaimReserve, activeBoostTokens, boostTokenIndex
    );
  }

  /// @notice Recover ERC20 tokens sent to this contract
  /// @dev For non-USDSC tokens or USDSC surplus when paused
  /// @param token Token address to recover
  /// @param to Address to send tokens to
  /// @param amount Amount to recover
  function recoverERC20(address token, address to, uint256 amount) external onlyOwner nonReentrant {
    if (to == address(0)) revert IEarnVaultEventsAndErrors.CanNotBeZeroAddress();

    if (token == address(USDSC)) {
      if (!paused()) revert IEarnVaultEventsAndErrors.ContractNotPaused();
      // allow sweeping only true surplus
      uint256 bal = USDSC.balanceOf(address(this));
      uint256 minRequired = claimReserve;
      if (bal <= minRequired) revert IEarnVaultEventsAndErrors.InsufficientFunding();
      uint256 maxSweep = bal - minRequired;
      if (amount > maxSweep) revert IEarnVaultEventsAndErrors.ExceedsSurplus();
    } else {
      // For non-USDSC tokens, check actual balance and boost reserves
      uint256 tokenBalance = IERC20(token).balanceOf(address(this));
      if (amount > tokenBalance) revert IEarnVaultEventsAndErrors.ExceedsSurplus();

      // For boost tokens, ensure we don't recover reserved amounts
      if (boostClaimReserve[token] > 0) {
        uint256 availableAmount = tokenBalance - boostClaimReserve[token];
        if (amount > availableAmount) revert IEarnVaultEventsAndErrors.ExceedsSurplus();
      }
    }
    IERC20(token).safeTransfer(to, amount);
    emit TokenRecovered(token, to, amount);
  }

  /// @notice Sweep excess USDSC yield to treasury (when vault has surplus above reserves)
  /// @dev Sweeps all surplus above minimum required reserves
  function sweepSurplusToTreasury() external onlyOwner nonReentrant {
    uint256 bal = USDSC.balanceOf(address(this));
    uint256 minRequired = claimReserve;

    if (bal <= minRequired) return; // No surplus to sweep

    uint256 surplus = bal - minRequired;
    USDSC.safeTransfer(treasury, surplus);
    emit SurplusSweptToTreasury(surplus);
  }

  /// @notice Sweep native ETH from contract (only owner)
  /// @dev Allows recovery of ETH sent via selfdestruct or other means
  /// @param to Address to send ETH to
  /// @param amount Amount of ETH to sweep
  function sweepNative(address payable to, uint256 amount) external onlyOwner nonReentrant {
    if (to == address(0)) revert IEarnVaultEventsAndErrors.CanNotBeZeroAddress();

    (bool success,) = to.call{value: amount}('');
    if (!success) revert IEarnVaultEventsAndErrors.SweepFailed();

    emit NativeSwept(to, amount);
  }

  /// @notice Remove a boost reward token from activeBoostTokens array (only owner)
  /// @dev Can be used to clean up tokens that are frozen or no longer used
  /// @dev Only allows removal if boostClaimReserve[token] == 0 (no pending claims)
  /// @param token Token address to remove from activeBoostTokens array
  function removeBoostRewardToken(address token) external onlyOwner nonReentrant {
    if (token == address(0)) revert IEarnVaultEventsAndErrors.CanNotBeZeroAddress();

    uint256 index = boostTokenIndex[token];
    if (index == 0) return;

    if (boostClaimReserve[token] > 0) {
      revert IEarnVaultEventsAndErrors.InsufficientBoostClaimReserve();
    }

    uint256 lastIndex = activeBoostTokens.length - 1;
    if (index != lastIndex + 1) {
      address lastToken = activeBoostTokens[lastIndex];
      activeBoostTokens[index - 1] = lastToken;
      boostTokenIndex[lastToken] = index;
    }

    activeBoostTokens.pop();
    delete boostTokenIndex[token];

    emit IEarnVaultEventsAndErrors.BoostRewardTokenRemoved(token);
  }

  // ================================================================
  // EXTERNAL FUNCTIONS (VIEW)
  // ================================================================

  function asset() external view returns (address) {
    return address(USDSC);
  }

  function claimable(address user) external view returns (uint256) {
    uint256 p = principal[user];
    if (p == 0) return accrued[user];

    uint256 ui = userIndex[user];
    uint256 gi = globalIndex;
    if (gi > ui) {
      uint256 owed = Math.mulDiv(p, gi - ui, RAY);
      return accrued[user] + owed;
    }
    return accrued[user];
  }

  /// @notice Get user's total value (principal + claimable interest)
  function totalValue(address user) external view returns (uint256) {
    uint256 p = principal[user];
    if (p == 0) return accrued[user];

    uint256 ui = userIndex[user];
    uint256 gi = globalIndex;
    if (gi > ui) {
      uint256 owed = Math.mulDiv(p, gi - ui, RAY);
      return p + accrued[user] + owed;
    }
    return p + accrued[user];
  }

  /// @notice Get user's complete account info in one call
  function getUserInfo(address user)
    external
    view
    returns (uint256 userPrincipal, uint256 userClaimable, uint256 userTotal, uint256 userLastIndex)
  {
    userPrincipal = principal[user];
    userLastIndex = userIndex[user];

    // Inline claimable logic to avoid expensive external call
    uint256 p = userPrincipal;
    uint256 ui = userLastIndex;
    uint256 gi = globalIndex;

    if (p == 0) {
      userClaimable = accrued[user];
    } else if (gi > ui) {
      uint256 owed = Math.mulDiv(p, gi - ui, RAY);
      userClaimable = accrued[user] + owed;
    } else {
      userClaimable = accrued[user];
    }

    userTotal = userPrincipal + userClaimable;
  }

  /// @notice Get vault's overall statistics
  function getVaultStats()
    external
    view
    returns (
      uint256 vaultTotalPrincipal,
      uint256 vaultClaimReserve,
      uint256 vaultGlobalIndex,
      uint256 vaultBalance,
      uint256 vaultCarryRay
    )
  {
    vaultTotalPrincipal = totalPrincipal;
    vaultClaimReserve = claimReserve;
    vaultGlobalIndex = globalIndex;
    vaultBalance = USDSC.balanceOf(address(this));
    vaultCarryRay = _carryRay;
  }

  /// @notice Get user's claimable boost rewards for a specific token
  /// @param user User address to check
  /// @param token Token address to check boost rewards for
  function getClaimableBoostReward(address user, address token) external view returns (uint256) {
    _checkNotBlacklisted(user);
    return BoostRewardsLib.getClaimableBoostReward(
      user, token, principal[user], userBoostIndex[user][token], boostGlobalIndex[token], userBoostAccrued
    );
  }

  /// @notice Get all claimable rewards for a user (USDSC yield + all boost rewards)
  /// @param user User address to check
  /// @return usdscClaimable Claimable USDSC yield
  /// @return boostTokens Array of boost token addresses
  /// @return boostAmounts Array of claimable amounts for each boost token
  function getAllClaimables(address user)
    external
    view
    returns (uint256 usdscClaimable, address[] memory boostTokens, uint256[] memory boostAmounts)
  {
    _checkNotBlacklisted(user);

    // Get USDSC claimable yield
    usdscClaimable = this.claimable(user);

    // Cache array length for gas optimization
    uint256 boostTokensLength = activeBoostTokens.length;

    // Get all active boost tokens
    boostTokens = new address[](boostTokensLength);
    boostAmounts = new uint256[](boostTokensLength);

    // Calculate claimable amounts for each boost token
    for (uint256 i = 0; i < boostTokensLength; i++) {
      address token = activeBoostTokens[i];
      boostTokens[i] = token;
      boostAmounts[i] = BoostRewardsLib.getClaimableBoostReward(
        user, token, principal[user], userBoostIndex[user][token], boostGlobalIndex[token], userBoostAccrued
      );
    }
  }

  // ================================================================
  // INTERNAL FUNCTIONS (STATE-CHANGING)
  // ================================================================

  /// @dev Settles user's accrued yield based on globalIndex difference
  /// @dev Must ALWAYS be called before modifying principal[user] or accrued[user]
  /// @dev For first-time users, sets userIndex to current globalIndex to prevent over-allocation
  /// @param user Address to settle
  function _settle(address user) internal {
    uint256 p = principal[user];
    if (p == 0) {
      userIndex[user] = globalIndex;
      return;
    }

    uint256 ui = userIndex[user];
    uint256 gi = globalIndex;
    if (gi > ui) {
      uint256 owed = Math.mulDiv(p, gi - ui, RAY);
      accrued[user] += owed;
    }
    userIndex[user] = gi; // Always update index for consistency
  }

  /// @dev Settles user's accrued boost rewards for a specific token
  /// @dev Same logic as _settle but for boost rewards
  /// @param user Address to settle
  /// @param token Token address to settle boost rewards for
  function _settleBoost(address user, address token) internal {
    uint256 p = principal[user];
    if (p == 0) {
      userBoostIndex[user][token] = boostGlobalIndex[token];
      return;
    }

    uint256 ui = userBoostIndex[user][token];
    uint256 gi = boostGlobalIndex[token];
    if (gi > ui) {
      BoostRewardsLib.settleBoost(user, token, p, ui, gi, userBoostAccrued);
    }
    userBoostIndex[user][token] = gi; // Always update index for consistency
  }

  // ================================================================
  // INTERNAL FUNCTIONS (VIEW)
  // ================================================================

  function _onlyYieldRedistributor() internal view {
    if (msg.sender != yieldRedistributor) revert IEarnVaultEventsAndErrors.NotYieldRedistributor();
  }

  function _onlyBoostRewardKeeper() internal view {
    if (msg.sender != boostRewardKeeper) revert IEarnVaultEventsAndErrors.NotBoostRewardKeeper();
  }

  function _onlyPauser() internal view {
    if (msg.sender != pauser) revert IEarnVaultEventsAndErrors.NotAuthorizedToPause();
  }

  /// @dev Check if user is not blacklisted, revert if they are
  /// @param user Address to check blacklist status for
  function _checkNotBlacklisted(address user) internal view {
    if (isBlacklisted[user]) revert IEarnVaultEventsAndErrors.AddressBlacklisted();
  }
}
