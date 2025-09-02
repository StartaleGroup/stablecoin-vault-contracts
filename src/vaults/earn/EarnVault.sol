// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IEarnVault} from "../../interfaces/vaults/earn/IEarnVault.sol";

/// @title EarnVault (OFF path, claimable yield)
/// @notice Users deposit USDR, accrue claimable USDR via index accounting, and can claim/withdraw anytime.
///         A distributor pushes yield: transfer USDR to this contract, then call onYieldReceived(amount).
/// Accounting:
///   - accUSDRPerShare is in RAY (1e27) for precision.
///   - User state: principal, rewardDebt, pending.
///   - When yield arrives and totalPrincipal>0: acc += amount*RAY/totalPrincipal.
///   - If totalPrincipal==0 at yield time: amount is parked until deposits exist (applyParkedYield()).
/// Invariant (funding): USDR balance >= totalPrincipal + totalPending + parkedYield.
contract EarnVault is IEarnVault, Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -------- Constants --------
    uint256 public constant RAY = 1e27;

    // -------- Immutables --------
    IERC20 public immutable USDR;

    // -------- Roles / endpoints --------
    address public distributor;   // allowed to call onYieldReceived/applyParkedYield
    address public treasury;      // sink for admin sweeps / optional parked handling

    // -------- Optional allowlist --------
    bool public allowlistEnabled;
    mapping(address => bool) public isAllowed;

    // -------- Vault accounting --------
    uint256 public totalPrincipal;       // sum of user principals
    uint256 public accUSDRPerShare;      // global index in RAY
    uint256 public parkedYield;          // yield received while totalPrincipal==0 (deferred)
    uint256 public totalPending;         // global sum of all users' pending

    struct User {
        uint256 principal;   // deposited principal
        uint256 rewardDebt;  // principal * accUSDRPerShare / RAY
        uint256 pending;     // accrued but unclaimed USDR
    }
    mapping(address => User) public users;

    // -------- Events --------
    event SetDistributor(address indexed who);
    event SetTreasury(address indexed who);
    event AllowlistModeSet(bool enabled);
    event AllowlistUpdated(address indexed who, bool allowed);

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event Claim(address indexed user, address indexed to, uint256 amount);

    event YieldApplied(uint256 amount, uint256 newAccPerShare);
    event YieldParked(uint256 amount, uint256 totalParked);
    event ParkedYieldApplied(uint256 amountApplied, uint256 remainingParked);

    event EmergencySweep(address indexed token, address indexed to, uint256 amount);

    // -------- Errors --------
    error NotDistributor();
    error NotAllowed();
    error ZeroAmount();
    error InsufficientPrincipal();
    error BadAddress();
    error NothingToClaim();
    error InvariantFunding(); // USDR balance insufficent

    constructor(address _usdr, address _owner, address _distributor, address _treasury) 
        Ownable(_owner) {
        if (_usdr == address(0) || _owner == address(0)) revert BadAddress();
        USDR = IERC20(_usdr);
        distributor = _distributor;
        treasury = _treasury;
        emit SetDistributor(_distributor);
        emit SetTreasury(_treasury);
    }

    // =========================
    // Admin / roles
    // =========================

    function setDistributor(address who) external onlyOwner {
        distributor = who;
        emit SetDistributor(who);
    }

    function setTreasury(address who) external onlyOwner {
        treasury = who;
        emit SetTreasury(who);
    }

    function setAllowlistMode(bool enabled) external onlyOwner {
        allowlistEnabled = enabled;
        emit AllowlistModeSet(enabled);
    }

    function setAllowed(address who, bool allowed) external onlyOwner {
        isAllowed[who] = allowed;
        emit AllowlistUpdated(who, allowed);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // =========================
    // Views
    // =========================

    function asset() external view returns (address) {
        return address(USDR);
    }

    function claimable(address user) external view returns (uint256) {
        User memory u = users[user];
        uint256 accumulated = (u.principal * accUSDRPerShare) / RAY;
        if (accumulated < u.rewardDebt) return u.pending; // guard (should not happen)
        return u.pending + (accumulated - u.rewardDebt);
    }

    // =========================
    // User flows
    // =========================

    function deposit(uint256 amount) external whenNotPaused nonReentrant {
        _checkAllow(msg.sender);
        if (amount == 0) revert ZeroAmount();

        _settle(msg.sender);
        users[msg.sender].principal += amount;
        totalPrincipal += amount;

        USDR.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposit(msg.sender, amount);
    }

    function depositWithPermit(
        uint256 amount,
        uint256 deadline,
        uint8 v, bytes32 r, bytes32 s
    ) external whenNotPaused nonReentrant {
        _checkAllow(msg.sender);
        if (amount == 0) revert ZeroAmount();

        IERC20Permit(address(USDR)).permit(msg.sender, address(this), amount, deadline, v, r, s);

        _settle(msg.sender);
        users[msg.sender].principal += amount;
        totalPrincipal += amount;

        USDR.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposit(msg.sender, amount);
    }

    function withdraw(uint256 amount) external whenNotPaused nonReentrant {
        if (amount == 0) revert ZeroAmount();

        _settle(msg.sender);
        User storage u = users[msg.sender];
        if (amount > u.principal) revert InsufficientPrincipal();

        u.principal -= amount;
        totalPrincipal -= amount;

        USDR.safeTransfer(msg.sender, amount);
        emit Withdraw(msg.sender, amount);
    }

    function claim() external whenNotPaused nonReentrant {
        uint256 amt = _settle(msg.sender);
        if (amt == 0) revert NothingToClaim();
        users[msg.sender].pending = 0;
        totalPending -= amt;
        USDR.safeTransfer(msg.sender, amt);
        emit Claim(msg.sender, msg.sender, amt);
    }

    function claimTo(address to) external whenNotPaused nonReentrant {
        if (to == address(0)) revert BadAddress();
        uint256 amt = _settle(msg.sender);
        if (amt == 0) revert NothingToClaim();
        users[msg.sender].pending = 0;
        totalPending -= amt;
        USDR.safeTransfer(to, amt);
        emit Claim(msg.sender, to, amt);
    }

    // =========================
    // Distributor hooks
    // =========================

    /// @dev Call AFTER transferring `amount` USDR to this contract.
    ///      Enforces funding: USDR.balance >= totalPrincipal + totalPending + parkedYield (+ amount if parking).
    function onYield(uint256 amount) external whenNotPaused {
        if (msg.sender != distributor && msg.sender != owner()) revert NotDistributor();
        if (amount == 0) revert ZeroAmount();

        uint256 bal = USDR.balanceOf(address(this));

        if (totalPrincipal == 0) {
            // parking: liabilities rise by `amount`
            if (bal < totalPrincipal + totalPending + parkedYield + amount) revert InvariantFunding();
            parkedYield += amount;
            emit YieldParked(amount, parkedYield);
            return;
        }

        // normal credit: liabilities rise exactly by `amount`
        if (bal < totalPrincipal + totalPending + parkedYield + amount) revert InvariantFunding();

        accUSDRPerShare += (amount * RAY) / totalPrincipal;
        emit YieldApplied(amount, accUSDRPerShare);
    }

    /// @dev Apply previously parked yield once deposits exist.
    function applyParkedYield() external whenNotPaused {
        if (msg.sender != distributor && msg.sender != owner()) revert NotDistributor();
        uint256 amt = parkedYield;
        if (amt == 0 || totalPrincipal == 0) return;

        // No extra funding check needed: funds were verified at park time and are held in balance.
        parkedYield = 0;
        accUSDRPerShare += (amt * RAY) / totalPrincipal;
        emit ParkedYieldApplied(amt, 0);
    }

    // =========================
    // Internal helpers
    // =========================

    // Settles user pending with current index; returns new pending balance.
    function _settle(address user) internal returns (uint256 newlyClaimable) {
        User storage u = users[user];
        uint256 accumulated = (u.principal * accUSDRPerShare) / RAY;

        if (accumulated >= u.rewardDebt) {
            uint256 delta = accumulated - u.rewardDebt;
            if (delta > 0) {
                u.pending += delta;
                totalPending += delta;
            }
        }
        u.rewardDebt = (u.principal * accUSDRPerShare) / RAY;
        return u.pending;
    }

    function _checkAllow(address user) internal view {
        if (allowlistEnabled && !isAllowed[user]) revert NotAllowed();
    }

    // =========================
    // Emergency (owner)
    // =========================

    /// @dev Emergency sweep of tokens other than USDR, or USDR *surplus* if paused.
    function emergencySweep(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert BadAddress();

        if (token == address(USDR)) {
            if (!paused()) revert(); // only when paused
            // allow sweeping only true surplus
            uint256 bal = USDR.balanceOf(address(this));
            uint256 minRequired = totalPrincipal + totalPending + parkedYield;
            require(bal > minRequired, "no surplus");
            uint256 maxSweep = bal - minRequired;
            require(amount <= maxSweep, "exceeds surplus");
        }
        IERC20(token).safeTransfer(to, amount);
        emit EmergencySweep(token, to, amount);
    }
}
