// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {Ownable2Step} from "lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {Pausable} from "lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IEarnVault} from "../../interfaces/vaults/earn/IEarnVault.sol";
import {IEarnVaultEventsAndErrors} from "../../interfaces/vaults/earn/IEarnVaultEventsAndErrors.sol";

/// @title EarnVault (claimable yield)
/// @notice Users deposit USDR, accrue claimable USDR via index accounting, and can claim/withdraw anytime.
///         A distributor pushes yield: transfer USDR to this contract, then call onYieldReceived(amount).
/// Accounting:
///   - globalIndex is in RAY (1e27) for precision.
///   - User state: principal, userIndex, accrued.
///   - When yield arrives and totalPrincipal>0: globalIndex += amount*RAY/totalPrincipal.
///   - If totalPrincipal==0 at yield time: amount is parked and transferred to treasury when deposits exist.
/// Invariant (funding): USDR balance >= claimReserve + parkedYield.
contract EarnVault is IEarnVault, IEarnVaultEventsAndErrors, Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -------- Constants --------
    uint256 public constant RAY = 1e27;  // High precision for yield calculations (MakerDAO standard)
    
    /// @dev Minimum delta threshold before applying to globalIndex (prevents gas waste on tiny yields)
    uint256 public constant MINIMUM_DELTA_THRESHOLD = 1e18;  // 1 RAY unit

    // -------- Immutables --------
    IERC20 public immutable USDR;

    // -------- Roles / endpoints --------
    address public yieldRedistributor;   // allowed to call onYield/applyParkedYield
    address public treasury;             // sink for admin sweeps (currently unused)
    address public pauser;               // allowed to pause/unpause the contract

    // -------- Optional blacklist --------
    mapping(address => bool) public isBlacklisted;

    // -------- Vault accounting --------
    uint256 public totalPrincipal;       // sum of user principals
    uint256 public globalIndex = RAY;    // global index (scaled 1e27 - RAY precision)
    uint256 public parkedYield;          // yield received while totalPrincipal==0 (deferred)
    uint256 public claimReserve;         // assets available to pay claims/withdraws
    uint256 public pendingDelta;         // accumulated small deltas not yet applied to globalIndex

    mapping(address => uint256) public principal;
    mapping(address => uint256) public userIndex;
    mapping(address => uint256) public accrued;

    // -------- Events and Errors --------
    // All events and errors are inherited from IEarnVaultEventsAndErrors interface

    constructor(address usdr, address owner, address yieldRedistributorAddr, address treasuryAddr, address pauserAddr) 
        Ownable(owner) {
        if (usdr == address(0) || owner == address(0)) revert CanNotBeZeroAddress();
        if (yieldRedistributorAddr == address(0) || treasuryAddr == address(0)) revert CanNotBeZeroAddress();
        if (pauserAddr == address(0)) revert CanNotBeZeroAddress();
        USDR = IERC20(usdr);
        yieldRedistributor = yieldRedistributorAddr;
        treasury = treasuryAddr;
        pauser = pauserAddr;
    }

    // =========================
    // Admin / roles
    // =========================

    /// @notice Set the yield redistributor address
    /// @param who New yield redistributor address
    function setYieldRedistributor(address who) external onlyOwner {
        if (who == address(0)) revert CanNotBeZeroAddress();
        address oldRedistributor = yieldRedistributor;
        yieldRedistributor = who;
        emit YieldRedistributorChanged(msg.sender, oldRedistributor, who);
    }

    /// @notice Set the treasury address  
    /// @param who New treasury address
    function setTreasury(address who) external onlyOwner {
        if (who == address(0)) revert CanNotBeZeroAddress();
        address oldTreasury = treasury;
        treasury = who;
        emit TreasuryChanged(msg.sender, oldTreasury, who);
    }

    /// @notice Set the pauser address
    /// @param who New pauser address
    function setPauser(address who) external onlyOwner {
        if (who == address(0)) revert CanNotBeZeroAddress();
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
    /// @dev Can be called by owner or designated pauser
    function pause() external {
        if (msg.sender != owner() && msg.sender != pauser) revert NotAuthorizedToPause();
        _pause();
    }

    /// @notice Unpause the contract
    /// @dev Can be called by owner or designated pauser  
    function unpause() external {
        if (msg.sender != owner() && msg.sender != pauser) revert NotAuthorizedToPause();
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
        uint256 vaultParkedYield,
        uint256 vaultGlobalIndex,
        uint256 vaultPendingDelta,
        uint256 vaultBalance
    ) {
        vaultTotalPrincipal = totalPrincipal;
        vaultClaimReserve = claimReserve;
        vaultParkedYield = parkedYield;
        vaultGlobalIndex = globalIndex;
        vaultPendingDelta = pendingDelta;
        vaultBalance = USDR.balanceOf(address(this));
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

    /// @notice Withdraw principal amount. Full withdrawals automatically claim all accrued interest.
    /// @dev Partial withdrawals do NOT auto-claim interest - use claim() separately for partial withdrawals.
    /// @param amount Principal amount to withdraw. If equals user's total principal, all interest is auto-claimed.
    function withdraw(uint256 amount) external whenNotPaused nonReentrant {
        _checkNotBlacklisted(msg.sender);  //   Add blacklist check
        if (amount == 0) revert ZeroAmount();

        _settle(msg.sender);
        uint256 p = principal[msg.sender];
        if (amount > p) revert InsufficientPrincipal();

        uint256 interestOut = 0;
        if (amount == p) {
            // Full withdrawal: auto-claim all accrued interest
            interestOut = accrued[msg.sender];
            accrued[msg.sender] = 0;
            if (claimReserve < interestOut) revert InsufficientFunding();
            claimReserve -= interestOut;
        }

        principal[msg.sender] = p - amount;
        totalPrincipal -= amount;
        claimReserve -= amount;

        USDR.safeTransfer(msg.sender, amount + interestOut);
        emit Withdraw(msg.sender, amount);
        if (interestOut > 0) {
            emit InterestClaimed(msg.sender, interestOut);
        }
    }

    /// @notice Claim all accrued interest to caller's address
    /// @dev Settles user's position and transfers all accrued yield
    function claim() external whenNotPaused nonReentrant {
        _checkNotBlacklisted(msg.sender);
        _settle(msg.sender);
        uint256 amt = accrued[msg.sender];
        if (amt == 0) revert NothingToClaim();
        if (claimReserve < amt) revert InsufficientFunding();
        
        accrued[msg.sender] = 0;
        claimReserve -= amt;
        USDR.safeTransfer(msg.sender, amt);
        emit InterestClaimed(msg.sender, amt);
    }

    // =========================
    // Distributor hooks
    // =========================

    /// @notice Distribute yield to vault users (callable only by yield redistributor)
    /// @dev MUST be called AFTER transferring `amount` USDR to this contract
    /// @dev Enforces funding invariant: USDR.balance >= claimReserve + parkedYield + amount
    /// @param amount Amount of USDR yield to distribute
    function onYield(uint256 amount) external whenNotPaused {
        if (msg.sender != yieldRedistributor) revert NotYieldRedistributor();
        if (amount == 0) return;
        
        // Verify actual balance before updating accounting (moved up to avoid duplication)
        uint256 bal = USDR.balanceOf(address(this));
        if (bal < claimReserve + parkedYield + amount) revert InsufficientFunding();
        
        if (totalPrincipal == 0) {
            // Park yield until deposits exist
            parkedYield += amount;
            emit YieldParked(amount, parkedYield);
            return;
        }
        
        // If we have parked yield and now have deposits, apply it first
        if (parkedYield > 0) {
            _applyParkedYieldInternal();
        }
        
        // Calculate and accumulate delta (prevents loss of small yields)
        uint256 delta = Math.mulDiv(amount, RAY, totalPrincipal);
        pendingDelta += delta;
        
        // Apply pending delta only when it reaches meaningful threshold
        if (pendingDelta >= MINIMUM_DELTA_THRESHOLD) {
            // Check for overflow before adding
            if (globalIndex + pendingDelta < globalIndex) revert ArithmeticOverflow();
            
            globalIndex += pendingDelta;
            pendingDelta = 0;  // Reset after application
        }
        
        claimReserve += amount;
        emit YieldIndexed(amount, globalIndex, claimReserve);
    }

    /// @notice Transfer previously parked yield to treasury
    /// @dev Only callable by yield redistributor to maintain atomic operations
    function applyParkedYield() external whenNotPaused {
        if (msg.sender != yieldRedistributor) revert NotYieldRedistributor();
        uint256 amt = parkedYield;
        if (amt == 0) return;

        // Transfer parked yield to treasury instead of distributing to users
        parkedYield = 0;
        USDR.safeTransfer(treasury, amt);
        emit ParkedYieldApplied(amt, 0);
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

    function _checkNotBlacklisted(address user) internal view {
        if (isBlacklisted[user]) revert AddressBlacklisted();
    }

    /// @dev Internal helper to transfer parked yield to treasury - called automatically in deposit
    function _applyParkedYieldInternal() internal {
        uint256 amt = parkedYield;
        if (amt == 0) return;
        
        // Transfer parked yield to treasury instead of distributing to users
        parkedYield = 0;
        USDR.safeTransfer(treasury, amt);
        emit ParkedYieldApplied(amt, 0);
    }

    // =========================
    // Emergency (owner)
    // =========================

    /// @dev Emergency sweep of tokens other than USDR, or USDR *surplus* if paused.
    function emergencySweep(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert CanNotBeZeroAddress();

        if (token == address(USDR)) {
            if (!paused()) revert ContractNotPaused();
            // allow sweeping only true surplus
            uint256 bal = USDR.balanceOf(address(this));
            uint256 minRequired = claimReserve + parkedYield;
            if (bal <= minRequired) revert InsufficientFunding();
            uint256 maxSweep = bal - minRequired;
            if (amount > maxSweep) revert ExceedsSurplus();
        } else {
            // For non-USDR tokens, check actual balance
            uint256 tokenBalance = IERC20(token).balanceOf(address(this));
            if (amount > tokenBalance) revert ExceedsSurplus();
        }
        IERC20(token).safeTransfer(to, amount);
        emit EmergencySweep(token, to, amount);
    }

    /// @notice Sweep excess USDR yield to treasury (when vault has surplus above reserves)
    /// @dev Only callable when paused for safety, sweeps all surplus above minimum required reserves
    function sweepSurplusToTreasury() external onlyOwner {
        if (!paused()) revert ContractNotPaused();
        
        uint256 bal = USDR.balanceOf(address(this));
        uint256 minRequired = claimReserve + parkedYield;
        
        if (bal <= minRequired) return; // No surplus to sweep
        
        uint256 surplus = bal - minRequired;
        USDR.safeTransfer(treasury, surplus);
        emit EmergencySweep(address(USDR), treasury, surplus);
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
