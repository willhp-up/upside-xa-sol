// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./UpsideXaTypes.sol";
import "./UpsideToken.sol";

/// @title Upside Xa Burn Mechanism
/// @notice Manages two types of burns:
///
/// 1. VOLUNTARY BURNS (bi-annual events):
///    Users burn up to 25% of available balance for a share of the distribution pool.
///    Lifecycle: Scheduled -> Open -> Processing -> Completed
///
/// 2. DECAY BURNS (automated):
///    Admin/oracle burns tokens from inactive users per the decay schedule.
///    Triggered by the off-chain decay service after manual review.

contract BurnMechanism {
    using UpsideXaTypes for *;

    // =========================================================================
    // STATE
    // =========================================================================

    uint32 public nextEventId = 1;
    mapping(uint32 => UpsideXaTypes.BurnEvent) public burnEvents;

    mapping(uint32 => mapping(address => uint256)) public userBurnAmount;
    mapping(uint32 => mapping(address => bool)) public userClaimed;

    // Totals
    uint256 public totalVoluntaryBurned;
    uint256 public totalDecayBurned;
    uint256 public totalBurnedAllTime;

    // Decay tracking
    mapping(address => uint256) public userDecayBurned;
    uint32 public decayBurnCount;

    // Access control
    address public admin;
    address public tokenContract;
    address public governanceContract;
    bool    public paused;

    // =========================================================================
    // EVENTS
    // =========================================================================

    event BurnEventCreated(uint32 eventId, uint256 distributionPool, uint256 opensAt, uint256 closesAt);
    event BurnEventOpened(uint32 eventId);
    event TokensBurned(address indexed user, uint32 eventId, uint256 amount);
    event BurnEventProcessing(uint32 eventId, uint256 totalBurned);
    event BurnEventCompleted(uint32 eventId, uint256 valuePerCoin);
    event PayoutClaimed(address indexed user, uint32 eventId, uint256 payout);
    event DecayBurnExecuted(address indexed user, uint256 amount, uint256 inactiveMonths);

    // =========================================================================
    // MODIFIERS
    // =========================================================================

    modifier onlyAdmin() { require(msg.sender == admin, "Not admin"); _; }
    modifier whenNotPaused() { require(!paused, "Paused"); _; }

    // =========================================================================
    // CONSTRUCTOR
    // =========================================================================

    constructor() {
        admin = msg.sender;
    }

    // =========================================================================
    // VOLUNTARY BURN EVENTS (Admin)
    // =========================================================================

    function createBurnEvent(
        uint256 distributionPool,
        uint256 opensAt,
        uint256 closesAt
    ) external onlyAdmin returns (uint32) {
        require(closesAt > opensAt, "Invalid time range");
        require(distributionPool > 0, "Pool must be > 0");

        uint32 eventId = nextEventId++;
        burnEvents[eventId] = UpsideXaTypes.BurnEvent({
            eventId: eventId,
            distributionPool: distributionPool,
            totalBurned: 0,
            valuePerCoin: 0,
            opensAt: opensAt,
            closesAt: closesAt,
            status: UpsideXaTypes.BurnEventStatus.Scheduled
        });

        emit BurnEventCreated(eventId, distributionPool, opensAt, closesAt);
        return eventId;
    }

    function openBurnEvent(uint32 eventId) external onlyAdmin {
        UpsideXaTypes.BurnEvent storage evt = burnEvents[eventId];
        require(evt.eventId != 0, "Event not found");
        require(evt.status == UpsideXaTypes.BurnEventStatus.Scheduled, "Not scheduled");
        evt.status = UpsideXaTypes.BurnEventStatus.Open;
        emit BurnEventOpened(eventId);
    }

    function closeBurnEvent(uint32 eventId) external onlyAdmin {
        UpsideXaTypes.BurnEvent storage evt = burnEvents[eventId];
        require(evt.eventId != 0, "Event not found");
        require(evt.status == UpsideXaTypes.BurnEventStatus.Open, "Not open");

        evt.status = UpsideXaTypes.BurnEventStatus.Processing;
        emit BurnEventProcessing(eventId, evt.totalBurned);

        if (evt.totalBurned > 0) {
            evt.valuePerCoin = (evt.distributionPool * 1e18) / evt.totalBurned;
        }

        evt.status = UpsideXaTypes.BurnEventStatus.Completed;
        emit BurnEventCompleted(eventId, evt.valuePerCoin);
    }

    // =========================================================================
    // VOLUNTARY BURNS (User)
    // =========================================================================

    function burnTokens(uint32 eventId, uint256 amount) external whenNotPaused {
        UpsideXaTypes.BurnEvent storage evt = burnEvents[eventId];
        require(evt.eventId != 0, "Event not found");
        require(evt.status == UpsideXaTypes.BurnEventStatus.Open, "Event not open");

        UpsideToken token = UpsideToken(tokenContract);
        uint256 available = token.availableBalanceOf(msg.sender);
        require(available > 0, "No available balance");

        uint256 maxBurn = (available * UpsideXaTypes.MAX_BURN_PERCENT_BPS) / UpsideXaTypes.BPS_DENOMINATOR;
        uint256 alreadyBurned = userBurnAmount[eventId][msg.sender];
        require(alreadyBurned + amount <= maxBurn, "Exceeds 25% burn cap");
        require(amount > 0, "Cannot burn zero");

        token.burnFrom(msg.sender, amount);

        userBurnAmount[eventId][msg.sender] = alreadyBurned + amount;
        evt.totalBurned += amount;
        totalVoluntaryBurned += amount;
        totalBurnedAllTime += amount;

        emit TokensBurned(msg.sender, eventId, amount);
    }

    function claimPayout(uint32 eventId) external whenNotPaused returns (uint256) {
        UpsideXaTypes.BurnEvent storage evt = burnEvents[eventId];
        require(evt.status == UpsideXaTypes.BurnEventStatus.Completed, "Not completed");
        require(!userClaimed[eventId][msg.sender], "Already claimed");

        uint256 burned = userBurnAmount[eventId][msg.sender];
        require(burned > 0, "Nothing burned");

        userClaimed[eventId][msg.sender] = true;
        uint256 payout = (burned * evt.valuePerCoin) / 1e18;

        if (payout > 0 && address(this).balance >= payout) {
            (bool sent, ) = payable(msg.sender).call{value: payout}("");
            require(sent, "Payout transfer failed");
        }

        emit PayoutClaimed(msg.sender, eventId, payout);
        return payout;
    }

    // =========================================================================
    // DECAY BURNS (Admin — triggered by off-chain decay service)
    // =========================================================================

    /// @notice Burn tokens from an inactive user as part of the decay mechanism.
    ///         Only callable by admin after off-chain decay service + manual review.
    /// @param user          The inactive user's address
    /// @param amount        UPC to burn (in wei, 18 decimals)
    /// @param inactiveMonths How many months the user has been inactive (for logging)
    function decayBurn(
        address user,
        uint256 amount,
        uint256 inactiveMonths
    ) external onlyAdmin {
        require(amount > 0, "Amount must be > 0");

        // Use token's adminBurn to remove from user's balance
        UpsideToken(tokenContract).adminBurn(user, amount);

        userDecayBurned[user] += amount;
        totalDecayBurned += amount;
        totalBurnedAllTime += amount;
        decayBurnCount++;

        emit DecayBurnExecuted(user, amount, inactiveMonths);
    }

    /// @notice Batch decay burn for multiple users (gas efficient).
    function decayBurnBatch(
        address[] calldata users,
        uint256[] calldata amounts,
        uint256[] calldata inactiveMonths
    ) external onlyAdmin {
        require(users.length == amounts.length && amounts.length == inactiveMonths.length, "Array mismatch");

        UpsideToken token = UpsideToken(tokenContract);
        for (uint256 i = 0; i < users.length; i++) {
            if (amounts[i] > 0) {
                token.adminBurn(users[i], amounts[i]);
                userDecayBurned[users[i]] += amounts[i];
                totalDecayBurned += amounts[i];
                totalBurnedAllTime += amounts[i];
                decayBurnCount++;
                emit DecayBurnExecuted(users[i], amounts[i], inactiveMonths[i]);
            }
        }
    }

    // =========================================================================
    // QUERIES
    // =========================================================================

    function getBurnEvent(uint32 eventId) external view returns (UpsideXaTypes.BurnEvent memory) { return burnEvents[eventId]; }
    function getUserBurn(uint32 eventId, address user) external view returns (uint256) { return userBurnAmount[eventId][user]; }
    function getUserDecayBurned(address user) external view returns (uint256) { return userDecayBurned[user]; }

    function maxBurnableFor(address user) external view returns (uint256) {
        UpsideToken token = UpsideToken(tokenContract);
        uint256 available = token.availableBalanceOf(user);
        return (available * UpsideXaTypes.MAX_BURN_PERCENT_BPS) / UpsideXaTypes.BPS_DENOMINATOR;
    }

    function eventCount() external view returns (uint32) { return nextEventId - 1; }

    function burnSummary() external view returns (
        uint256 voluntary,
        uint256 decay,
        uint256 total,
        uint32  decayCount
    ) {
        return (totalVoluntaryBurned, totalDecayBurned, totalBurnedAllTime, decayBurnCount);
    }

    // =========================================================================
    // ADMIN
    // =========================================================================

    function setTokenContract(address _token) external onlyAdmin { tokenContract = _token; }
    function setGovernanceContract(address _gov) external onlyAdmin { governanceContract = _gov; }
    function setPaused(bool _paused) external {
        require(msg.sender == admin || msg.sender == governanceContract, "Not admin or governance");
        paused = _paused;
    }
    function transferAdmin(address newAdmin) external onlyAdmin { admin = newAdmin; }

    receive() external payable {}
}
