// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {AccessControl} from "lib/openzeppelin-contracts/contracts/access/AccessControl.sol";
import {Pausable} from "lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IEarnVault} from "../../interfaces/vaults/earn/IEarnVault.sol";
import {IEarnVaultEventsAndErrors} from "../../interfaces/vaults/earn/IEarnVaultEventsAndErrors.sol";
import {BoostRewardsLib} from "./BoostRewardsLib.sol";

/// @title EarnVault (claimable yield)
/// @notice Users deposit USDR, accrue claimable USDR via index accounting, and can claim/withdraw anytime.
///         A distributor pushes yield: transfer USDR to this contract, then call onYield(amount).
/// Accounting:
///   - globalIndex is in RAY (1e27) for precision.
///   - User state: principal, userIndex, accrued.
///   - When yield arrives and totalPrincipal>0: globalIndex += amount*RAY/totalPrincipal.
///   - If totalPrincipal==0 at yield time: amount is transferred directly to treasury.
/// Invariant (funding): USDR balance >= claimReserve.
contract EarnVault is IEarnVault, IEarnVaultEventsAndErrors, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -------- Constants --------
    uint256 public constant RAY = 1e27;  // High precision for yield calculations (MakerDAO standard)
    
    
    
    // -------- Roles --------
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant YIELD_REDISTRIBUTOR_ROLE = keccak256("YIELD_REDISTRIBUTOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // -------- Immutables --------
    IERC20 public immutable USDR;


    // -------- Roles / endpoints --------
    address public treasury;             // receives yield when no deposits exist, surplus sweeps
    address public currentPauser;        // current pauser (for role management)

    // -------- Optional blacklist --------
    mapping(address => bool) public isBlacklisted;

    // -------- Vault accounting --------
    uint256 public totalPrincipal;       // sum of user principals
    uint256 public globalIndex = RAY;    // global index (scaled 1e27 - RAY precision)
    uint256 public claimReserve;         // assets available to pay claims/withdraws
    uint256 private _carryRay;           // remainder in "RAY * principal" space for exact precision

    mapping(address => uint256) public principal;
    mapping(address => uint256) public userIndex;
    mapping(address => uint256) public accrued;

    // -------- Boost rewards accounting (same logic as USDR yield) --------
    mapping(address => uint256) public boostGlobalIndex; // token => global boost index
    mapping(address => uint256) public boostClaimReserve; // token => claimable boost reserves
    mapping(address => mapping(address => uint256)) public userBoostIndex; // user => token => last boost index
    mapping(address => mapping(address => uint256)) public userBoostAccrued; // user => token => accrued boost rewards
    address[] public activeBoostTokens; // list of tokens that have been distributed
    mapping(address => uint256) public boostTokenIndex; // token => index in activeBoostTokens array

    // -------- Events and Errors --------
    // All events and errors are inherited from IEarnVaultEventsAndErrors interface

    constructor(address usdr, address admin, address yieldRedistributorAddr, address treasuryAddr, address pauserAddr) {
        if (usdr == address(0) || admin == address(0)) revert CanNotBeZeroAddress();
        if (yieldRedistributorAddr == address(0) || treasuryAddr == address(0)) revert CanNotBeZeroAddress();
        if (pauserAddr == address(0)) revert CanNotBeZeroAddress();
        
        USDR = IERC20(usdr);
        treasury = treasuryAddr;
        currentPauser = pauserAddr;
        
        // Set up roles
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(YIELD_REDISTRIBUTOR_ROLE, yieldRedistributorAddr);
        _grantRole(PAUSER_ROLE, pauserAddr);
    }

    // =========================
    // Admin / roles
    // =========================

    /// @notice Set the yield redistributor address
    /// @param who New yield redistributor address
    function setYieldRedistributor(address who) external onlyRole(ADMIN_ROLE) {
        if (who == address(0)) revert CanNotBeZeroAddress();
        // Note: We can't easily get the old address without storage, so we emit address(0) for old
        // In practice, this is fine since the role system is the source of truth
        _grantRole(YIELD_REDISTRIBUTOR_ROLE, who);
        emit YieldRedistributorChanged(msg.sender, address(0), who);
    }

    /// @notice Set the treasury address  
    /// @param who New treasury address
    function setTreasury(address who) external onlyRole(ADMIN_ROLE) {
        if (who == address(0)) revert CanNotBeZeroAddress();
        address oldTreasury = treasury;
        treasury = who;
        emit TreasuryChanged(msg.sender, oldTreasury, who);
    }

    /// @notice Set the pauser address
    /// @param who New pauser address
    function setPauser(address who) external onlyRole(ADMIN_ROLE) {
        if (who == address(0)) revert CanNotBeZeroAddress();
        address oldPauser = currentPauser;
        
        // Revoke role from old pauser
        _revokeRole(PAUSER_ROLE, oldPauser);
        // Grant role to new pauser
        _grantRole(PAUSER_ROLE, who);
        
        currentPauser = who;
        emit PauserChanged(msg.sender, oldPauser, who);
    }


    /// @notice Set blacklist status for an address
    /// @param who Address to update blacklist status for
    /// @param blacklisted Whether address should be blacklisted
    function setBlacklisted(address who, bool blacklisted) external onlyRole(ADMIN_ROLE) {
        bool oldStatus = isBlacklisted[who];
        isBlacklisted[who] = blacklisted;
        emit BlacklistStatusChanged(msg.sender, who, oldStatus, blacklisted);
    }

    /// @notice Pause the contract (emergency stop)
    /// @dev Can be called by admin or designated pauser
    function pause() external {
        if (!hasRole(ADMIN_ROLE, msg.sender) && !hasRole(PAUSER_ROLE, msg.sender)) revert NotAuthorizedToPause();
        _pause();
    }
    
    /// @notice Unpause the contract
    /// @dev Can be called by admin or designated pauser  
    function unpause() external {
        if (!hasRole(ADMIN_ROLE, msg.sender) && !hasRole(PAUSER_ROLE, msg.sender)) revert NotAuthorizedToPause();
        _unpause();
    }

    // =========================
    // Views
    // =========================

    function asset() external view returns (address) {
        return address(USDR);
    }

    function claimable(address user) external view returns (uint256) {
        uint256 p = principal[user];
        uint256 ui = userIndex[user];
        uint256 gi = globalIndex;
        if (p == 0) return accrued[user];
        if (gi > ui) {
            uint256 owed = Math.mulDiv(p, gi - ui, RAY);
            return accrued[user] + owed;
        }
        return accrued[user];
    }

    /// @notice Get user's total value (principal + claimable interest)
    function totalValue(address user) external view returns (uint256) {
        uint256 p = principal[user];
        uint256 ui = userIndex[user];
        uint256 gi = globalIndex;
        if (p == 0) return accrued[user];
        if (gi > ui) {
            uint256 owed = Math.mulDiv(p, gi - ui, RAY);
            return p + accrued[user] + owed;
        }
        return p + accrued[user];
    }

    /// @notice Get user's complete account info in one call
    function getUserInfo(address user) external view returns (
        uint256 userPrincipal,
        uint256 userClaimable, 
        uint256 userTotal,
        uint256 userLastIndex
    ) {
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
    function getVaultStats() external view returns (
        uint256 vaultTotalPrincipal,
        uint256 vaultClaimReserve,
        uint256 vaultGlobalIndex,
        uint256 vaultBalance,
        uint256 vaultCarryRay
    ) {
        vaultTotalPrincipal = totalPrincipal;
        vaultClaimReserve = claimReserve;
        vaultGlobalIndex = globalIndex;
        vaultBalance = USDR.balanceOf(address(this));
        vaultCarryRay = _carryRay;
    }

    /// @notice Get user's claimable boost rewards for a specific token
    /// @param user User address to check
    /// @param token Token address to check boost rewards for
    function getClaimableBoostReward(address user, address token) external view returns (uint256) {
        _checkNotBlacklisted(user);
        return BoostRewardsLib.getClaimableBoostReward(
            user,
            token,
            principal[user],
            userBoostIndex[user][token],
            boostGlobalIndex[token],
            userBoostAccrued
        );
    }

    /// @notice Get all claimable rewards for a user (USDR yield + all boost rewards)
    /// @param user User address to check
    /// @return usdrClaimable Claimable USDR yield
    /// @return boostTokens Array of boost token addresses
    /// @return boostAmounts Array of claimable amounts for each boost token
    function getAllClaimables(address user) external view returns (
        uint256 usdrClaimable,
        address[] memory boostTokens,
        uint256[] memory boostAmounts
    ) {
        _checkNotBlacklisted(user);
        
        // Get USDR claimable yield
        usdrClaimable = this.claimable(user);
        
        // Get all active boost tokens
        boostTokens = new address[](activeBoostTokens.length);
        boostAmounts = new uint256[](activeBoostTokens.length);
        
        // Calculate claimable amounts for each boost token
        for (uint256 i = 0; i < activeBoostTokens.length; i++) {
            address token = activeBoostTokens[i];
            boostTokens[i] = token;
            boostAmounts[i] = BoostRewardsLib.getClaimableBoostReward(
                user,
                token,
                principal[user],
                userBoostIndex[user][token],
                boostGlobalIndex[token],
                userBoostAccrued
            );
        }
    }

    // =========================
    // User flows
    // =========================

    /// @notice Deposit USDR tokens to earn yield
    /// @dev Reserves principal 1:1 in claimReserve to ensure withdrawals are always possible
    /// @param amount Amount of USDR tokens to deposit
    function deposit(uint256 amount) external whenNotPaused nonReentrant {
        _checkNotBlacklisted(msg.sender);
        if (amount == 0) revert ZeroAmount();

        _settle(msg.sender);
        
        USDR.safeTransferFrom(msg.sender, address(this), amount);
        principal[msg.sender] += amount;
        totalPrincipal += amount;
        claimReserve += amount;  // reserve principal 1:1

        emit Deposit(msg.sender, amount);
    }

    /// @notice Deposit USDR tokens using permit (gasless approval)
    /// @dev Same as deposit() but uses permit for approval in same transaction
    /// @dev Safely handles tokens that may not implement IERC20Permit
    /// @param amount Amount of USDR tokens to deposit
    /// @param deadline Permit deadline timestamp
    /// @param v Permit signature parameter v
    /// @param r Permit signature parameter r  
    /// @param s Permit signature parameter s
    function depositWithPermit(
        uint256 amount,
        uint256 deadline,
        uint8 v, bytes32 r, bytes32 s
    ) external whenNotPaused nonReentrant {
        _checkNotBlacklisted(msg.sender);
        if (amount == 0) revert ZeroAmount();

        // Safely attempt permit - revert with clear error if not supported
        try IERC20Permit(address(USDR)).permit(msg.sender, address(this), amount, deadline, v, r, s) {
            // Permit succeeded, continue with deposit
        } catch {
            revert PermitFailed();
        }

        _settle(msg.sender);
        
        USDR.safeTransferFrom(msg.sender, address(this), amount);
        principal[msg.sender] += amount;
        totalPrincipal += amount;
        claimReserve += amount;  // reserve principal 1:1

        emit Deposit(msg.sender, amount);
    }

    /// @notice Withdraw any amount up to principal amount
    /// @param amount Amount of principal to withdraw (max: user's principal)
    /// @dev Automatically claims ALL accrued interest (USDR + boost rewards) when withdrawing
    /// @dev User can only withdraw their principal, but gets all rewards automatically
    function withdraw(uint256 amount) external whenNotPaused nonReentrant {
        _checkNotBlacklisted(msg.sender);
        if (amount == 0) revert ZeroAmount();

        _settle(msg.sender);
        
        uint256 p = principal[msg.sender];
        if (amount > p) revert InsufficientPrincipal();

        // Settle ALL boost rewards BEFORE reducing principal
        for (uint256 i = 0; i < activeBoostTokens.length; i++) {
            _settleBoost(msg.sender, activeBoostTokens[i]);
        }

        // Update state AFTER settling all rewards
        principal[msg.sender] = p - amount;
        totalPrincipal -= amount;
        claimReserve -= amount; // Reduce claim reserve by withdrawn principal
        
        // Transfer principal
        USDR.safeTransfer(msg.sender, amount);
        
        // Automatically claim ALL USDR yield
        uint256 usdrYield = accrued[msg.sender];
        if (usdrYield > 0) {
            if (claimReserve < usdrYield) revert InsufficientFunding();
            accrued[msg.sender] = 0;
            claimReserve -= usdrYield;
            USDR.safeTransfer(msg.sender, usdrYield);
            emit InterestClaimed(msg.sender, usdrYield);
        }
        
        // Automatically claim ALL boost rewards
        for (uint256 i = 0; i < activeBoostTokens.length; i++) {
            address token = activeBoostTokens[i];
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
        
        // Emit events
        emit Withdraw(msg.sender, amount);
    }


    /// @notice Claim all accrued interest to caller's address
    /// @dev Settles user's position and transfers all accrued yield (USDR + boost rewards)
    function claim() external whenNotPaused nonReentrant {
        _checkNotBlacklisted(msg.sender);
        _settle(msg.sender);
        
        // Settle ALL boost rewards BEFORE any state changes
        for (uint256 i = 0; i < activeBoostTokens.length; i++) {
            _settleBoost(msg.sender, activeBoostTokens[i]);
        }
        
        uint256 usdrAmt = accrued[msg.sender];
        bool hasUSDRClaim = usdrAmt > 0;
        bool hasBoostClaim = false;
        
        // Claim USDR interest
        if (hasUSDRClaim) {
            if (claimReserve < usdrAmt) revert InsufficientFunding();
            accrued[msg.sender] = 0;
            claimReserve -= usdrAmt;
            USDR.safeTransfer(msg.sender, usdrAmt);
            emit InterestClaimed(msg.sender, usdrAmt);
        }
        
        // Claim all boost rewards
        for (uint256 i = 0; i < activeBoostTokens.length; i++) {
            address token = activeBoostTokens[i];
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
        
        if (!hasUSDRClaim && !hasBoostClaim) revert NothingToClaim();
    }


    // =========================
    // Distributor hooks
    // =========================

    /// @notice Distribute yield to vault users (callable only by yield redistributor)
    /// @dev MUST be called AFTER transferring `amount` USDR to this contract
    /// @dev Enforces funding invariant: USDR.balance >= claimReserve + amount
    /// @param amount Amount of USDR yield to distribute
    function onYield(uint256 amount) external onlyRole(YIELD_REDISTRIBUTOR_ROLE) nonReentrant {
        if (amount == 0) return;
        
        // Verify actual balance before updating accounting
        uint256 bal = USDR.balanceOf(address(this));
        
        if (totalPrincipal == 0) {
            // No deposits: just need enough for treasury transfer
            if (bal < amount) revert InsufficientFunding();
            USDR.safeTransfer(treasury, amount);
            emit YieldTransferredToTreasury(amount);
            return;
        }
        
        // Deposits exist: need enough for claimReserve + new yield
        if (bal < claimReserve + amount) revert InsufficientFunding();
        
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
    /// @dev Uses same logic as USDR yield - distributed proportionally based on principal
    /// @param token Token address to distribute as boost rewards
    /// @param amount Amount of boost tokens to distribute
    function onBoostReward(address token, uint256 amount) external onlyRole(YIELD_REDISTRIBUTOR_ROLE) nonReentrant {
        BoostRewardsLib.distributeBoostReward(
            token,
            amount,
            totalPrincipal,
            treasury,
            boostGlobalIndex,
            boostClaimReserve,
            activeBoostTokens,
            boostTokenIndex
        );
    }

    // =========================
    // Internal helpers
    // =========================

    /// @dev Settles user's accrued yield based on globalIndex difference
    /// @dev Must ALWAYS be called before modifying principal[user] or accrued[user]
    /// @dev For first-time users, sets userIndex to current globalIndex to prevent over-allocation
    /// @param user Address to settle
    function _settle(address user) internal {
        uint256 p = principal[user];
        uint256 ui = userIndex[user];
        uint256 gi = globalIndex;
        if (p == 0) { 
            userIndex[user] = gi; 
            return; 
        }
        if (gi >= ui) {
            if (gi > ui) {
                uint256 owed = Math.mulDiv(p, gi - ui, RAY);
                accrued[user] += owed;
            }
            userIndex[user] = gi;  // Always update index for consistency
        }
    }

    /// @dev Settles user's accrued boost rewards for a specific token
    /// @dev Same logic as _settle but for boost rewards
    /// @param user Address to settle
    /// @param token Token address to settle boost rewards for
    function _settleBoost(address user, address token) internal {
        BoostRewardsLib.settleBoost(
            user,
            token,
            principal[user],
            userBoostIndex[user][token],
            boostGlobalIndex[token],
            userBoostAccrued
        );
        userBoostIndex[user][token] = boostGlobalIndex[token];
    }

    /// @dev Check if user is not blacklisted, revert if they are
    /// @param user Address to check blacklist status for
    function _checkNotBlacklisted(address user) internal view {
        if (isBlacklisted[user]) revert AddressBlacklisted();
    }


    // =========================
    // Emergency (owner)
    // =========================

    /// @notice Recover ERC20 tokens sent to this contract
    /// @dev For non-USDR tokens or USDR surplus when paused
    /// @param token Token address to recover
    /// @param to Address to send tokens to
    /// @param amount Amount to recover
    function recoverERC20(address token, address to, uint256 amount) external onlyRole(ADMIN_ROLE) {
        if (to == address(0)) revert CanNotBeZeroAddress();

        if (token == address(USDR)) {
            if (!paused()) revert ContractNotPaused();
            // allow sweeping only true surplus
            uint256 bal = USDR.balanceOf(address(this));
            uint256 minRequired = claimReserve;
            if (bal <= minRequired) revert InsufficientFunding();
            uint256 maxSweep = bal - minRequired;
            if (amount > maxSweep) revert ExceedsSurplus();
        } else {
            // For non-USDR tokens, check actual balance and boost reserves
            uint256 tokenBalance = IERC20(token).balanceOf(address(this));
            if (amount > tokenBalance) revert ExceedsSurplus();
            
            // For boost tokens, ensure we don't recover reserved amounts
            if (boostClaimReserve[token] > 0) {
                uint256 availableAmount = tokenBalance - boostClaimReserve[token];
                if (amount > availableAmount) revert ExceedsSurplus();
            }
        }
        IERC20(token).safeTransfer(to, amount);
        emit TokenRecovered(token, to, amount);
    }

    /// @notice Sweep excess USDR yield to treasury (when vault has surplus above reserves)
    /// @dev Sweeps all surplus above minimum required reserves
    function sweepSurplusToTreasury() external onlyRole(ADMIN_ROLE) {
        uint256 bal = USDR.balanceOf(address(this));
        uint256 minRequired = claimReserve;
        
        if (bal <= minRequired) return; // No surplus to sweep
        
        uint256 surplus = bal - minRequired;
        USDR.safeTransfer(treasury, surplus);
        emit SurplusSweptToTreasury(surplus);
    }

    // =========================
    // ETH Safety
    // =========================

    /// @dev Reject ETH transfers to prevent accidental loss
    receive() external payable {
        revert EthNotAccepted();
    }

    /// @dev Reject ETH transfers to prevent accidental loss
    fallback() external payable {
        revert EthNotAccepted();
    }
}
