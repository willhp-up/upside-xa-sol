// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./UpsideXaTypes.sol";
import "./UpsideToken.sol";

/// @title Upside Xa Idea Staking
/// @notice On-chain record of stakes that mirrors the off-chain API.
///
/// The API (Node/Express/MongoDB) handles all the complex staking math:
/// return calculations, conviction curves, early endorser bonuses, etc.
/// This contract provides the on-chain commitment layer:
///
/// 1. User stakes UPC on an idea → tokens locked on-chain
/// 2. Oracle/admin reports settlement → tokens returned/burned
/// 3. On-chain record provides transparency and auditability
///
/// Flow:
///   recordStake()    → locks tokens (available → staked)
///   settleWin()      → returns stake + mints reward
///   settleLoss()     → burns slashed portion, returns remainder
///   decayBurn()      → burns tokens from inactive users

contract IdeaStaking {
    using UpsideXaTypes for *;

    // =========================================================================
    // STATE
    // =========================================================================

    uint64 public nextStakeId = 1;
    mapping(uint64 => UpsideXaTypes.StakeRecord) public stakes;

    // Per-user tracking
    mapping(address => uint64[]) public userStakeIds;
    mapping(address => uint256) public userTotalStaked;     // Currently locked
    mapping(address => uint256) public userTotalReturned;
    mapping(address => uint256) public userTotalBurned;

    // Per-idea tracking
    mapping(uint64 => uint64[]) public ideaStakeIds;
    mapping(uint64 => uint256) public ideaTotalStaked;

    // Global stats
    uint256 public totalStaked;
    uint256 public totalReturned;
    uint256 public totalBurned;
    uint256 public totalSettled;

    // Access control
    address public admin;
    address public oracle;          // Can settle stakes
    address public tokenContract;
    address public governanceContract;
    bool    public paused;

    // =========================================================================
    // EVENTS
    // =========================================================================

    event StakeRecorded(uint64 stakeId, address indexed user, uint64 ideaId, uint8 stakeType, uint256 amount);
    event StakeSettledWin(uint64 stakeId, address indexed user, uint256 returned, uint256 reward);
    event StakeSettledLoss(uint64 stakeId, address indexed user, uint256 returned, uint256 burned);
    event DecayBurnExecuted(address indexed user, uint256 amount, string reason);

    // =========================================================================
    // MODIFIERS
    // =========================================================================

    modifier onlyAdmin() { require(msg.sender == admin, "Not admin"); _; }
    modifier onlyOracle() { require(msg.sender == oracle || msg.sender == admin, "Not oracle"); _; }
    modifier whenNotPaused() { require(!paused, "Paused"); _; }

    // =========================================================================
    // CONSTRUCTOR
    // =========================================================================

    constructor() {
        admin = msg.sender;
    }

    // =========================================================================
    // STAKE RECORDING
    // =========================================================================

    /// @notice Record a stake on-chain. Called by admin/oracle after API validates.
    ///         Transfers tokens from user to this contract (escrow).
    function recordStake(
        address user,
        uint64  ideaId,
        uint8   stakeType,   // 0=Self, 1=Endorsement, 2=Community
        uint256 amount
    ) external whenNotPaused onlyOracle returns (uint64) {
        require(amount > 0, "Amount must be > 0");
        require(stakeType <= 2, "Invalid stake type");

        // Transfer tokens from user to this contract (requires prior approval)
        UpsideToken token = UpsideToken(tokenContract);
        require(token.availableBalanceOf(user) >= amount, "Insufficient available balance");

        // User must have approved this contract to spend their tokens
        token.transferFrom(user, address(this), amount);

        uint64 stakeId = nextStakeId++;
        stakes[stakeId] = UpsideXaTypes.StakeRecord({
            stakeId: stakeId,
            user: user,
            ideaId: ideaId,
            stakeType: UpsideXaTypes.StakeType(stakeType),
            amount: amount,
            stakedAt: block.timestamp,
            status: UpsideXaTypes.StakeStatus.Active,
            returnAmount: 0,
            burnAmount: 0,
            settledAt: 0
        });

        userStakeIds[user].push(stakeId);
        userTotalStaked[user] += amount;
        ideaStakeIds[ideaId].push(stakeId);
        ideaTotalStaked[ideaId] += amount;
        totalStaked += amount;

        emit StakeRecorded(stakeId, user, ideaId, stakeType, amount);
        return stakeId;
    }

    // =========================================================================
    // SETTLEMENT
    // =========================================================================

    /// @notice Settle a winning stake. Returns original + reward.
    ///         Reward is minted by the issuance contract (off-chain triggers).
    ///         This function just returns the escrowed stake.
    function settleWin(
        uint64  stakeId,
        uint256 rewardAmount    // Informational — actual reward minted separately
    ) external whenNotPaused onlyOracle {
        UpsideXaTypes.StakeRecord storage stake = stakes[stakeId];
        require(stake.stakeId != 0, "Stake not found");
        require(stake.status == UpsideXaTypes.StakeStatus.Active || stake.status == UpsideXaTypes.StakeStatus.Scored, "Not active");

        stake.status = UpsideXaTypes.StakeStatus.Settled;
        stake.returnAmount = stake.amount + rewardAmount;
        stake.settledAt = block.timestamp;

        // Return escrowed tokens to user
        UpsideToken(tokenContract).transfer(stake.user, stake.amount);

        userTotalStaked[stake.user] -= stake.amount;
        userTotalReturned[stake.user] += stake.amount;
        totalReturned += stake.amount;
        totalSettled++;

        emit StakeSettledWin(stakeId, stake.user, stake.amount, rewardAmount);
    }

    /// @notice Settle a losing stake. Burns slashed portion, returns remainder.
    function settleLoss(
        uint64  stakeId,
        uint256 burnAmount,     // Portion to burn (based on graduated slashing)
        uint256 treasuryAmount  // Portion to send to treasury (informational)
    ) external whenNotPaused onlyOracle {
        UpsideXaTypes.StakeRecord storage stake = stakes[stakeId];
        require(stake.stakeId != 0, "Stake not found");
        require(stake.status == UpsideXaTypes.StakeStatus.Active || stake.status == UpsideXaTypes.StakeStatus.Scored, "Not active");
        require(burnAmount + treasuryAmount <= stake.amount, "Slash exceeds stake");

        stake.status = UpsideXaTypes.StakeStatus.Slashed;
        stake.burnAmount = burnAmount;
        uint256 returnToUser = stake.amount - burnAmount - treasuryAmount;
        stake.returnAmount = returnToUser;
        stake.settledAt = block.timestamp;

        UpsideToken token = UpsideToken(tokenContract);

        // Return remainder to user
        if (returnToUser > 0) {
            token.transfer(stake.user, returnToUser);
        }

        // Burn the slashed portion (this contract holds the tokens)
        // We approve the burn contract to take them, then trigger burn
        // OR: admin burns directly from this contract's balance
        // Simplest: transfer to admin who can then burn or treasury them
        // For now: we just hold burned tokens in contract (effectively burned from user's perspective)
        // The admin can sweep them to treasury or call adminBurn later

        userTotalStaked[stake.user] -= stake.amount;
        userTotalReturned[stake.user] += returnToUser;
        userTotalBurned[stake.user] += burnAmount;
        totalReturned += returnToUser;
        totalBurned += burnAmount;
        totalSettled++;

        emit StakeSettledLoss(stakeId, stake.user, returnToUser, burnAmount);
    }

    // =========================================================================
    // DECAY BURNS
    // =========================================================================

    /// @notice Burn tokens from an inactive user's on-chain balance.
    ///         Called by admin after the off-chain decay service determines burn amount.
    function decayBurn(
        address user,
        uint256 amount,
        string calldata reason
    ) external onlyAdmin {
        require(amount > 0, "Amount must be > 0");

        // Use token's adminBurn to remove from user's balance directly
        UpsideToken(tokenContract).adminBurn(user, amount);

        userTotalBurned[user] += amount;
        totalBurned += amount;

        emit DecayBurnExecuted(user, amount, reason);
    }

    // =========================================================================
    // QUERIES
    // =========================================================================

    function getStake(uint64 stakeId) external view returns (UpsideXaTypes.StakeRecord memory) {
        return stakes[stakeId];
    }

    function getUserStakeCount(address user) external view returns (uint256) {
        return userStakeIds[user].length;
    }

    function getUserStakeIds(address user) external view returns (uint64[] memory) {
        return userStakeIds[user];
    }

    function getIdeaStakeIds(uint64 ideaId) external view returns (uint64[] memory) {
        return ideaStakeIds[ideaId];
    }

    function getUserSummary(address user) external view returns (
        uint256 currentlyStaked,
        uint256 totalReturnedAmount,
        uint256 totalBurnedAmount,
        uint256 stakeCount
    ) {
        return (
            userTotalStaked[user],
            userTotalReturned[user],
            userTotalBurned[user],
            userStakeIds[user].length
        );
    }

    // =========================================================================
    // ADMIN
    // =========================================================================

    function setOracle(address _oracle) external {
        require(msg.sender == admin || msg.sender == governanceContract, "Not authorized");
        oracle = _oracle;
    }
    function setTokenContract(address _token) external onlyAdmin { tokenContract = _token; }
    function setGovernanceContract(address _gov) external onlyAdmin { governanceContract = _gov; }
    function setPaused(bool _paused) external {
        require(msg.sender == admin || msg.sender == governanceContract, "Not admin or governance");
        paused = _paused;
    }
    function transferAdmin(address newAdmin) external onlyAdmin { admin = newAdmin; }

    /// @notice Sweep tokens held in this contract (slashed/burned) to treasury.
    function sweepToTreasury(address treasury) external onlyAdmin {
        UpsideToken token = UpsideToken(tokenContract);
        uint256 contractBalance = token.availableBalanceOf(address(this));
        if (contractBalance > 0) {
            token.transfer(treasury, contractBalance);
        }
    }
}
